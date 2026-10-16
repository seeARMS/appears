import CoreGraphics
import Foundation
import Synchronization
import Testing

@testable import AppearsCore

/// Re-enters the indexer while it awaits an embedding, as a file watcher can.
private actor RescanningEmbedder: Embedder {
    nonisolated let modelID = "rescan-test"
    nonisolated let dimension = 64
    nonisolated let supportsImages = false
    private let hashing = HashingEmbedder(dimension: 64)
    private var duringEmbedding: (@Sendable () async throws -> Void)?

    func onEmbedding(_ work: @escaping @Sendable () async throws -> Void) {
        duringEmbedding = work
    }

    func embed(queries: [String]) async throws -> [[Float]] {
        try await hashing.embed(queries: queries)
    }

    func embed(documents: [EmbeddingDocument]) async throws -> [[Float]] {
        if let work = duringEmbedding {
            duringEmbedding = nil
            try await work()
        }
        return try await hashing.embed(documents: documents)
    }

    func embed(images: [CGImage]) async throws -> [[Float]] {
        try await hashing.embed(images: images)
    }
}

@Suite struct IndexerProgressTests {
    @Test func rescanPreservesActiveIndexingAndFindsNewFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "appears-progress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try IndexStore(url: folder.appending(path: ".index/index.sqlite"))
        let embedder = RescanningEmbedder()
        let indexer = Indexer(
            store: store, vectors: VectorIndex(dimension: embedder.dimension), embedder: embedder,
            settings: SourceSettings(notes: false, messages: false, homeOverride: folder.path)
        )
        await indexer.setPoliteness(false)
        let updates = Mutex<[IndexProgress]>([])
        await indexer.setProgressHandler { progress in updates.withLock { $0.append(progress) } }
        try "Kitchen renovation quote from Dana Ruiz.".write(
            to: folder.appending(path: "quote.txt"), atomically: true, encoding: .utf8
        )

        #expect(try await indexer.scanFiles() == 1)
        #expect(updates.withLock { $0.first?.phase } == .scanning)
        #expect(await indexer.progress.phase == .idle)
        #expect(await indexer.progress.scanned == 1)
        updates.withLock { $0.removeAll() }

        await embedder.onEmbedding {
            let before = await indexer.progress
            #expect(before.phase == .indexing)
            try "Cabinet installation scheduled for Thursday.".write(
                to: folder.appending(path: "schedule.txt"), atomically: true, encoding: .utf8
            )
            #expect(try await indexer.scanFiles() == 2)
            #expect(await indexer.progress == before)
            #expect(updates.withLock { $0.allSatisfy { $0.phase == .indexing } })
            #expect(try store.counts().waiting == 2)
        }

        #expect(try await indexer.indexPending() == 2)
        #expect(try store.counts().indexedTotal == 2)
        #expect(try store.counts().waiting == 0)
        #expect(await indexer.progress.phase == .idle)
        #expect(updates.withLock { $0.dropLast().allSatisfy { $0.phase == .indexing } })
    }
}
