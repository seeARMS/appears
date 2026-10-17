import CoreGraphics
import Foundation

/// A model forward cannot be interrupted safely. Between forwards, queries take the
/// next slot ahead of indexing. Cancellation removes a waiter without running its work.
actor EmbeddingScheduler {
    enum Priority: Sendable { case interactive, indexing }
    private struct Waiter {
        let id: UUID
        let priority: Priority
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var busy = false
    private var waiters: [Waiter] = []

    func run<T: Sendable>(priority: Priority, operation: @Sendable () async throws -> T) async throws -> T {
        let queued = ContinuousClock.now
        do { try await acquire(priority) }
        catch {
            SearchTrace.current?.record(.embeddingQueue, since: queued)
            throw error
        }
        defer { release() }
        SearchTrace.current?.record(.embeddingQueue, since: queued)
        try Task.checkCancellation()
        let started = ContinuousClock.now
        defer { SearchTrace.current?.record(.embedding, since: started) }
        let result = try await operation()
        try Task.checkCancellation()
        return result
    }

    private func acquire(_ priority: Priority) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if !busy {
                    busy = true
                    continuation.resume()
                } else {
                    waiters.append(Waiter(id: id, priority: priority, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        guard !waiters.isEmpty else { busy = false; return }
        let next = waiters.firstIndex { $0.priority == .interactive } ?? 0
        waiters.remove(at: next).continuation.resume()
    }

    // Also lets deterministic tests wait until work is actually queued.
    var waiting: Int { waiters.count }
}

/// The engine uses the same scheduler for recall and indexing, with one safe model
/// operation at a time. Images yield individually, even when a PDF contains many pages.
final class ScheduledEmbedder: Embedder, UnloadsVision {
    let base: any Embedder
    let scheduler = EmbeddingScheduler()
    var modelID: String { base.modelID }
    var dimension: Int { base.dimension }
    var supportsImages: Bool { base.supportsImages }

    init(_ base: any Embedder) { self.base = base }

    func embed(queries: [String]) async throws -> [[Float]] {
        try await scheduler.run(priority: .interactive) { try await self.base.embed(queries: queries) }
    }

    func embed(documents: [EmbeddingDocument]) async throws -> [[Float]] {
        var result: [[Float]] = []
        for batch in documents.chunked(8) {
            let documents = Array(batch)
            result += try await scheduler.run(priority: .indexing) { try await self.base.embed(documents: documents) }
        }
        return result
    }

    func embed(passages: [EmbeddingDocument]) async throws -> [[Float]] {
        try await scheduler.run(priority: .interactive) { try await self.base.embed(passages: passages) }
    }

    func embed(images: [CGImage]) async throws -> [[Float]] {
        var result: [[Float]] = []
        for image in images {
            result += try await scheduler.run(priority: .indexing) { try await self.base.embed(images: [image]) }
        }
        return result
    }

    func prepare(image: CGImage) throws -> PreparedImageEmbedding {
        let prepared = try base.prepare(image: image)
        return PreparedImageEmbedding {
            try await self.scheduler.run(priority: .indexing) { try await prepared.vector() }
        }
    }

    func unloadVision() async {
        guard let base = base as? any UnloadsVision else { return }
        _ = try? await scheduler.run(priority: .indexing) { await base.unloadVision() }
    }
}
