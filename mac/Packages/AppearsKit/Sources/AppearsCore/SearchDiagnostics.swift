import Foundation
import os
import Synchronization

/// Durations only: no query, context, paths, source text, or result identifiers.
public struct SearchTimings: Sendable, Codable, Equatable {
    public var preparationMilliseconds = 0.0
    public var embeddingQueueMilliseconds = 0.0
    public var embeddingMilliseconds = 0.0
    public var vectorMilliseconds = 0.0
    public var fullTextMilliseconds = 0.0
    public var rankingMilliseconds = 0.0
    public var totalMilliseconds = 0.0
}

final class SearchTrace: Sendable {
    @TaskLocal static var current: SearchTrace?
    enum Phase { case preparation, embeddingQueue, embedding, vector, fullText, ranking }
    private let started = ContinuousClock.now
    private let timings = Mutex(SearchTimings())
    private static let log = Logger(subsystem: "rs.appea.appears", category: "search")

    func record(_ phase: Phase, since start: ContinuousClock.Instant) {
        let ms = Self.milliseconds(since: start)
        timings.withLock {
            switch phase {
            case .preparation: $0.preparationMilliseconds += ms
            case .embeddingQueue: $0.embeddingQueueMilliseconds += ms
            case .embedding: $0.embeddingMilliseconds += ms
            case .vector: $0.vectorMilliseconds += ms
            case .fullText: $0.fullTextMilliseconds += ms
            case .ranking: $0.rankingMilliseconds += ms
            }
        }
    }

    func finish(outcome: String) -> SearchTimings {
        let value = timings.withLock {
            $0.totalMilliseconds = Self.milliseconds(since: started)
            return $0
        }
        Self.log.info("Search \(outcome, privacy: .public): prepare \(value.preparationMilliseconds, privacy: .public)ms, model wait \(value.embeddingQueueMilliseconds, privacy: .public)ms, model \(value.embeddingMilliseconds, privacy: .public)ms, vectors \(value.vectorMilliseconds, privacy: .public)ms, full text \(value.fullTextMilliseconds, privacy: .public)ms, ranking \(value.rankingMilliseconds, privacy: .public)ms, total \(value.totalMilliseconds, privacy: .public)ms")
        return value
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
    }
}
