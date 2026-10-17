import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import AppearsCore

private actor PhotoGate {
    var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private actor PhotoEvents {
    var reads: [Int] = []
    var forwards: [String] = []
    var firstImageAndPrefetchStarted: Bool { forwards == ["image1"] && reads.count == 2 }
    func read(_ id: Int) { reads.append(id) }
    func forward(_ value: String) { forwards.append(value) }
}

private struct PhotoEmbedder: Embedder {
    let modelID = "photo-prefetch-test", dimension = 4, supportsImages = true
    let events: PhotoEvents
    var onImage: @Sendable (Int) async throws -> Void = { _ in }
    func embed(queries: [String]) async throws -> [[Float]] {
        await events.forward("query")
        return queries.map { _ in [0, 0, 0, 1] }
    }
    func embed(documents: [EmbeddingDocument]) async throws -> [[Float]] {
        documents.map { _ in [0, 0, 0, 1] }
    }
    func embed(images: [CGImage]) async throws -> [[Float]] {
        var result: [[Float]] = []
        for image in images { result.append(try await prepare(image: image).vector()) }
        return result
    }
    func prepare(image: CGImage) throws -> PreparedImageEmbedding {
        PreparedImageEmbedding {
            await events.forward("image\(image.width)")
            try await onImage(image.width)
            return [Float(image.width), 0, 0, 1]
        }
    }
}

private struct PhotoFixture {
    let folder: URL
    let store: IndexStore
    let vectors = VectorIndex(dimension: 4)
    let items: [Item]
    let settings: SourceSettings
    init(count: Int = 3, source: ItemSource = .file) throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "appears-prefetch-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = try IndexStore(url: folder.appending(path: "index.sqlite"))
        settings = SourceSettings(notes: false, messages: true, homeOverride: folder.path)
        let folder = folder, store = store
        items = try (1...count).map { number in
            let url = folder.appending(path: "\(number).png")
            try Data("synthetic photo \(number)".utf8).write(to: url)
            var item = Item(source: source, path: source == .messages ? "messages:\(number):photo:fixture" : url.path,
                            kind: .image, title: "Photo \(number)", size: 17, created: .distantPast,
                            modified: Date(timeIntervalSince1970: Double(100 - number)), lastUsed: nil,
                            message: source == .messages ? MessageReference(rowID: Int64(number), guid: "fixture-\(number)",
                                chatID: 1, conversationURL: nil, attachmentPath: url.path) : nil)
            item.id = try store.record(item, signature: "version1").id
            return item
        }
    }
    func indexer(_ base: PhotoEmbedder, extract: (@Sendable (Int) async -> Void)? = nil) -> Indexer {
        Indexer(store: store, vectors: vectors, embedder: ScheduledEmbedder(base), settings: settings,
                photoExtraction: { item in
            let number = Int(item.fileURL!.deletingPathExtension().lastPathComponent)!
            await base.events.read(number)
            await extract?(number)
            let context = CGContext(data: nil, width: number, height: 1, bitsPerComponent: 8, bytesPerRow: number * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            var extraction = Extraction()
            extraction.images = [(.whole, context.makeImage()!, "Synthetic OCR")]
            return extraction
        })
    }
}

private func photoSettled(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while try await !condition() {
        if ContinuousClock.now > deadline { throw PhotoTestFailure.didNotSettle }
        try await Task.sleep(for: .milliseconds(1))
    }
}
private enum PhotoTestFailure: Error { case didNotSettle }

@Suite(.timeLimit(.minutes(1))) struct PhotoPrefetchTests {
    @Test func preparesOnlyOneFollowingPhotoAndQueriesTakeTheNextModelSlot() async throws {
        let fixture = try PhotoFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let events = PhotoEvents(), finish = PhotoGate()
        let indexer = fixture.indexer(PhotoEmbedder(events: events, onImage: { id in if id == 1 { await finish.wait() } }))
        await indexer.setPoliteness(false)
        let run = Task { try await indexer.indexPending() }
        try await photoSettled { await events.firstImageAndPrefetchStarted }
        #expect(await events.reads == [1, 2])
        let embedder = await indexer.embedder
        let scheduled = try #require(embedder as? ScheduledEmbedder)
        let query = Task { try await scheduled.embed(queries: ["synthetic query"]) }
        try await photoSettled { await scheduled.scheduler.waiting == 1 }
        await finish.open()
        _ = try await query.value
        #expect(try await run.value == 3)
        #expect(await events.forwards == ["image1", "query", "image2", "image3"])
        #expect(try fixture.store.counts().indexedTotal == 3)
    }

    @Test func cancellationDrainsPreparationBeforeAnotherRun() async throws {
        let fixture = try PhotoFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let events = PhotoEvents(), model = PhotoGate(), preparation = PhotoGate()
        let indexer = fixture.indexer(PhotoEmbedder(events: events, onImage: { id in if id == 1 { await model.wait() } }),
                                     extract: { id in if id == 2 { await preparation.wait() } })
        await indexer.setPoliteness(false)
        let ended = Mutex(false)
        let run = Task { defer { ended.withLock { $0 = true } }; return try await indexer.indexPending() }
        try await photoSettled { await events.firstImageAndPrefetchStarted }
        run.cancel()
        await model.open()
        // The decoder deliberately ignores cancellation until its gate opens.
        #expect(!ended.withLock { $0 })
        await preparation.open()
        do { _ = try await run.value; Issue.record("Cancelled indexing returned successfully") }
        catch { #expect(error is CancellationError) }
        #expect(try fixture.store.counts().units == 0)
        #expect(await events.reads == [1, 2])
        #expect(try await indexer.indexPending() == 3)
    }

    @Test(arguments: [ItemSource.file, .messages])
    func settingsChangesDiscardCurrentAndPrefetchedPhotos(source: ItemSource) async throws {
        let fixture = try PhotoFixture(source: source)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let events = PhotoEvents(), finish = PhotoGate()
        let indexer = fixture.indexer(PhotoEmbedder(events: events, onImage: { id in if id == 1 { await finish.wait() } }))
        await indexer.setPoliteness(false)
        let run = Task { try await indexer.indexPending() }
        try await photoSettled { await events.firstImageAndPrefetchStarted }
        var settings = fixture.settings
        if source == .messages { settings.messages = false }
        else { settings.excludes = [fixture.folder.path] }
        try await indexer.update(settings: settings)
        await finish.open()
        _ = try await run.value
        #expect(try fixture.store.counts().units == 0)
        #expect(try fixture.store.paths(source: source).isEmpty)
        #expect(await events.forwards == ["image1"])
    }

    @Test func changedSignaturesRetryWithoutSavingOldVectors() async throws {
        let fixture = try PhotoFixture(count: 2)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let events = PhotoEvents(), finish = PhotoGate()
        let indexer = fixture.indexer(PhotoEmbedder(events: events, onImage: { id in if id == 1 { await finish.wait() } }))
        await indexer.setPoliteness(false)
        let run = Task { try await indexer.indexPending() }
        try await photoSettled { await events.firstImageAndPrefetchStarted }
        for item in fixture.items { try fixture.store.record(item, signature: "version2") }
        await finish.open()
        _ = try await run.value
        #expect(await events.reads == [1, 2, 1, 2])
        #expect(await events.forwards == ["image1", "image1", "image2"])
        #expect(try fixture.store.counts().units == 2)
    }

    @Test(arguments: [false, true], [ItemSource.file, .messages])
    func fileEditsAndDeletionsDiscardPreparedPixels(delete: Bool, source: ItemSource) async throws {
        let fixture = try PhotoFixture(count: 2, source: source)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let events = PhotoEvents(), finish = PhotoGate()
        let indexer = fixture.indexer(PhotoEmbedder(events: events, onImage: { id in if id == 1 { await finish.wait() } }))
        await indexer.setPoliteness(false)
        // Exercise an edit which retains the scanner's whole-second signature.
        let second = Date().timeIntervalSince1970.rounded(.down)
        for var item in fixture.items {
            item.modified = Date(timeIntervalSince1970: second + 0.1)
            try FileManager.default.setAttributes([.modificationDate: item.modified], ofItemAtPath: item.fileURL!.path)
            try fixture.store.record(item, signature: FileScanner.signature(item))
        }
        let run = Task { try await indexer.indexPending() }
        try await photoSettled { await events.firstImageAndPrefetchStarted }
        for item in fixture.items {
            if delete { try FileManager.default.removeItem(at: item.fileURL!) }
            else {
                try Data("Synthetic changed".utf8).write(to: item.fileURL!)
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: second + 0.2)],
                                                     ofItemAtPath: item.fileURL!.path)
            }
        }
        await finish.open()
        _ = try await run.value
        #expect(try fixture.store.counts().units == (delete ? 0 : 2))
        #expect(try fixture.store.counts().waiting == 0)
        #expect(await events.forwards == (delete ? ["image1"] : ["image1", "image1", "image2"]))
    }

    @Test func timedOutOldWorkDoesNotFailAChangedSignatureOrLoseThePrefetch() async throws {
        let fixture = try PhotoFixture(count: 2)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let events = PhotoEvents(), finish = PhotoGate(), first = Mutex(true)
        let indexer = fixture.indexer(PhotoEmbedder(events: events, onImage: { id in
            if id == 1, first.withLock({ value in defer { value = false }; return value }) {
                await finish.wait()
                throw TimeoutError(seconds: 0.01)
            }
        }))
        await indexer.setPoliteness(false)
        let run = Task { try await indexer.indexPending() }
        try await photoSettled { await events.firstImageAndPrefetchStarted }
        try fixture.store.record(fixture.items[0], signature: "version2")
        await finish.open()
        _ = try await run.value
        #expect(try fixture.store.counts().indexedTotal == 2)
        #expect(await events.reads == [1, 2, 1])
    }
}
