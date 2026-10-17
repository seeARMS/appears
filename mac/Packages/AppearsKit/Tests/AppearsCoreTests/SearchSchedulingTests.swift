import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import AppearsCore

private actor Signal {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

private actor Operations {
    var values: [String] = []
    func add(_ value: String) { values.append(value) }
}

private func settled(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw SchedulingFailure.didNotSettle }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private enum SchedulingFailure: Error { case didNotSettle }

private func emptyResponse() -> RecallResponse {
    RecallResponse(suggestions: [], query: .init(entities: [], rareTerms: [], denseCharacters: 20), milliseconds: 0)
}

@Suite struct SearchSchedulingTests {
    @Test func evidenceScoringTakesTheNextSlotAheadOfIndexing() async throws {
        let base = ImageBatchEmbedder()
        let scheduled = ScheduledEmbedder(base)
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let current = Task { try await scheduled.embed(images: [image]) }
        await base.started.wait()
        let background = Task { try await scheduled.embed(documents: [.init(title: "", text: "Indexing")]) }
        try await settled { await scheduled.scheduler.waiting == 1 }
        let evidence = Task { try await scheduled.embed(passages: [.init(title: "", text: "Evidence")]) }
        try await settled { await scheduled.scheduler.waiting == 2 }
        await base.finish.open()
        _ = try await current.value
        _ = try await evidence.value
        _ = try await background.value
        #expect(await base.order == ["image", "passage", "document"])
    }

    @Test func aMultiImageBatchYieldsToAQueryBetweenImages() async throws {
        let base = ImageBatchEmbedder()
        let scheduled = ScheduledEmbedder(base)
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let indexing = Task { try await scheduled.embed(images: [image, image]) }
        await base.started.wait()
        let query = Task { try await scheduled.embed(queries: ["synthetic query"]) }
        try await settled { await scheduled.scheduler.waiting == 1 }
        await base.finish.open()
        _ = try await query.value
        _ = try await indexing.value
        #expect(await base.order == ["image", "query", "image"])
    }

    @Test func queriesTakeTheNextModelSlotAndCancelledWaitersNeverRun() async throws {
        let scheduler = EmbeddingScheduler()
        let started = Signal(), finish = Signal(), order = Operations()
        let current = Task {
            try await scheduler.run(priority: .indexing) {
                await started.open()
                await finish.wait()
                await order.add("current image")
            }
        }
        await started.wait()
        let background = Task {
            try await scheduler.run(priority: .indexing) { await order.add("next image") }
        }
        try await settled { await scheduler.waiting == 1 }
        let cancelledTrace = SearchTrace()
        let obsolete = Task {
            try await SearchTrace.$current.withValue(cancelledTrace) {
                try await scheduler.run(priority: .interactive) { await order.add("obsolete query") }
            }
        }
        try await settled { await scheduler.waiting == 2 }
        obsolete.cancel()
        do { try await obsolete.value; Issue.record("A cancelled queued query ran") }
        catch { #expect(error is CancellationError) }
        #expect(cancelledTrace.finish(outcome: "cancelled").embeddingQueueMilliseconds > 0)
        let latest = Task {
            try await scheduler.run(priority: .interactive) { await order.add("latest query") }
        }
        try await settled { await scheduler.waiting == 2 }
        #expect(await order.values.isEmpty, "The running model operation must not overlap another forward")
        await finish.open()
        try await current.value
        try await latest.value
        try await background.value
        #expect(await order.values == ["current image", "latest query", "next image"])
    }

    @Test func replacingARequestDoesNotWaitForItsOldResponse() async throws {
        let coordinator = SearchCoordinator()
        let started = Signal(), finish = Signal()
        let session = UUID()
        let first = SearchToken(session: session, revision: 1)
        let second = SearchToken(session: session, revision: 2)
        let old = Task {
            try await coordinator.run(first) {
                await started.open()
                await finish.wait() // Simulates work which cannot be interrupted mid-forward.
                return emptyResponse()
            }
        }
        await started.wait()
        _ = try await coordinator.run(second) { emptyResponse() }
        // An old cancellation arriving after the new request must leave it valid.
        await coordinator.cancel(first)
        await finish.open()
        do { _ = try await old.value; Issue.record("A superseded request returned a response") }
        catch { #expect(error is CancellationError) }
    }

    @Test func cancellationBeforeArrivalAndOutOfOrderRequestsCannotReviveOldWork() async throws {
        let coordinator = SearchCoordinator(), operations = Operations()
        let session = UUID()
        await coordinator.cancel(SearchToken(session: session, revision: 4))
        for revision: UInt64 in [2, 4] {
            do {
                _ = try await coordinator.run(SearchToken(session: session, revision: revision)) {
                    await operations.add("obsolete")
                    return emptyResponse()
                }
                Issue.record("An already cancelled revision ran")
            } catch { #expect(error is CancellationError) }
        }
        let started = Signal(), finish = Signal()
        let latest = Task {
            try await coordinator.run(SearchToken(session: session, revision: 5)) {
                await started.open()
                await finish.wait()
                return emptyResponse()
            }
        }
        await started.wait()
        await coordinator.cancel(SearchToken(session: session, revision: 3))
        await finish.open()
        _ = try await latest.value
        #expect(await operations.values.isEmpty)
    }

    @Test func engineCancellationRemovesObsoleteEmbeddingsAndReturnsDurationsOnly() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "appears-scheduling-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let base = ControlledEmbedder()
        let engine = try Engine(folder: folder, embedder: base, settings: SourceSettings(notes: false, messages: false))
        let scheduled = try #require(engine.embedder as? ScheduledEmbedder)
        let indexing = Task { try await engine.embedder.embed(documents: [.init(title: "Fixture", text: "Synthetic background work")]) }
        await base.started.wait()
        let session = UUID()
        let oldToken = SearchToken(session: session, revision: 1)
        let latestToken = SearchToken(session: session, revision: 2)
        let old = Task {
            try await engine.handle(.search, payload: JSONEncoder().encode(SearchRequest(text: "obsolete synthetic query", token: oldToken)))
        }
        try await settled { await scheduled.scheduler.waiting == 1 }
        _ = try await engine.handle(.cancelSearch, payload: JSONEncoder().encode(oldToken))
        do { _ = try await old.value; Issue.record("A cancelled engine request completed") }
        catch { #expect(error is CancellationError) }
        let latest = Task {
            try await engine.handle(.search, payload: JSONEncoder().encode(SearchRequest(text: "latest synthetic query", token: latestToken)))
        }
        try await settled { await scheduled.scheduler.waiting == 1 }
        await base.finish.open()
        _ = try await indexing.value
        let response = try JSONDecoder().decode(RecallResponse.self, from: await latest.value)
        #expect(await base.queries == ["latest synthetic query"])
        let timings = try #require(response.timings)
        #expect(timings.embeddingQueueMilliseconds > 0)
        #expect(timings.embeddingMilliseconds >= 0 && timings.totalMilliseconds > 0)
        let encoded = String(decoding: try JSONEncoder().encode(timings), as: UTF8.self)
        #expect(!encoded.contains("synthetic") && !encoded.contains("query"))
    }

    @Test func sourceChangesDuringEmbeddingCannotReturnExcludedContent() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "appears-sources-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let base = ControlledEmbedder(blockQueries: true)
        let settings = SourceSettings(notes: false, messages: false, homeOverride: folder.path)
        let engine = try Engine(folder: folder.appending(path: "Engine"), embedder: base, settings: settings)
        let request = Task {
            try await engine.handle(.search, payload: JSONEncoder().encode(SearchRequest(text: "a synthetic source query")))
        }
        await base.started.wait()
        var updated = settings
        updated.excludes = [folder.path]
        _ = try await engine.handle(.settings, payload: JSONEncoder().encode(updated))
        await base.finish.open()
        do { _ = try await request.value; Issue.record("A search used an obsolete source configuration") }
        catch { #expect(error is CancellationError) }
    }
}

private actor ImageBatchEmbedder: Embedder {
    nonisolated let modelID = "image-batch-fixture"
    nonisolated let dimension = 3
    nonisolated let supportsImages = true
    let started = Signal(), finish = Signal()
    var order: [String] = []
    func embed(queries: [String]) async throws -> [[Float]] {
        order.append("query")
        return queries.map { _ in [1, 0, 0] }
    }
    func embed(documents: [EmbeddingDocument]) async throws -> [[Float]] {
        order.append("document")
        return documents.map { _ in [1, 0, 0] }
    }
    func embed(passages: [EmbeddingDocument]) async throws -> [[Float]] {
        order.append("passage")
        return passages.map { _ in [1, 0, 0] }
    }
    func embed(images: [CGImage]) async throws -> [[Float]] {
        #expect(images.count == 1, "A query must not wait behind every image in a PDF")
        order.append("image")
        if order.count == 1 { await started.open(); await finish.wait() }
        return images.map { _ in [1, 0, 0] }
    }
}

private actor ControlledEmbedder: Embedder {
    nonisolated let modelID = "controlled-fixture"
    nonisolated let dimension = 3
    nonisolated let supportsImages = false
    let started = Signal(), finish = Signal()
    let blockQueries: Bool
    var queries: [String] = []
    init(blockQueries: Bool = false) { self.blockQueries = blockQueries }
    func embed(queries: [String]) async throws -> [[Float]] {
        self.queries += queries
        if blockQueries { await started.open(); await finish.wait() }
        return queries.map { _ in [1, 0, 0] }
    }
    func embed(documents: [EmbeddingDocument]) async throws -> [[Float]] {
        await started.open()
        await finish.wait()
        return documents.map { _ in [1, 0, 0] }
    }
    func embed(images: [CGImage]) async throws -> [[Float]] { [] }
}

/// A deliberately blocked filesystem walk with a timeout so regressions fail instead
/// of stranding the test process. It runs on the detached walker, never a Swift actor.
private final class BlockedWalk: Sendable {
    let started = DispatchSemaphore(value: 0)
    let finish = DispatchSemaphore(value: 0)
    let counts = Mutex((walks: 0, timedOut: false))
    func walk(_ scanner: FileScanner) -> [Item] {
        let first = counts.withLock { $0.walks += 1; return $0.walks == 1 }
        if first {
            started.signal()
            let result = finish.wait(timeout: .now() + 5)
            counts.withLock { $0.timedOut = result == .timedOut }
        }
        return scanner.settings.excludes.isEmpty
            ? [Item(source: .file, path: scanner.home + "/fixture.txt", kind: .document, title: "Synthetic fixture",
                    size: 1, created: .now, modified: .now, lastUsed: nil)] : []
    }
    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { self.started.wait(); continuation.resume() }
        }
    }
}

@Suite struct FileScanSchedulingTests {
    @Test func blockedWalkLeavesSettingsAndProgressResponsiveAndDiscardsOldSettings() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "appears-walk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let walk = BlockedWalk()
        defer { walk.finish.signal() }
        let store = try IndexStore(url: folder.appending(path: "index.sqlite"))
        let settings = SourceSettings(notes: false, messages: false, homeOverride: folder.path)
        let indexer = Indexer(store: store, vectors: VectorIndex(dimension: 3), embedder: ControlledEmbedder(),
                              settings: settings, fileWalk: walk.walk)
        let scan = Task { try await indexer.scanFiles() }
        await walk.waitUntilStarted()
        #expect(await indexer.settings == settings)
        #expect(await indexer.progress.phase == .scanning)
        var updated = settings
        updated.excludes = [folder.path]
        try await indexer.update(settings: updated)
        #expect(!walk.counts.withLock { $0.timedOut }, "Actor access must finish while the filesystem is still blocked")
        walk.finish.signal()
        #expect(try await scan.value == 0)
        #expect(walk.counts.withLock { $0.walks } == 2, "A settings change requests one fresh scan")
        #expect(try store.counts().items == 0, "A walk under obsolete settings cannot restore excluded files")
    }

    @Test func repeatedRescansShareOneWalkAndOneFollowUp() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "appears-coalesce-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let walk = BlockedWalk()
        defer { walk.finish.signal() }
        let store = try IndexStore(url: folder.appending(path: "index.sqlite"))
        let indexer = Indexer(store: store, vectors: VectorIndex(dimension: 3), embedder: ControlledEmbedder(),
                              settings: SourceSettings(notes: false, messages: false, homeOverride: folder.path), fileWalk: walk.walk)
        let first = Task { try await indexer.scanFiles() }
        await walk.waitUntilStarted()
        let followers = (0..<20).map { _ in Task { try await indexer.scanFiles() } }
        // Allow all incoming callbacks to reach the shared, still-blocked scan.
        try await Task.sleep(for: .milliseconds(50))
        #expect(walk.counts.withLock { $0.walks } == 1)
        walk.finish.signal()
        _ = try await first.value
        for follower in followers { _ = try await follower.value }
        #expect(walk.counts.withLock { $0.walks } == 2)
        #expect(try store.counts().items == 1)
    }
}
