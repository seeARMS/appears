import Accelerate
import Foundation
import Synchronization

/// Every unit's vector in memory, searched by brute force.
///
/// Vectors are float16 rows in one array. A search converts chunks of rows to float32 and
/// multiplies them by the query with Accelerate, spread across cores. A personal file
/// collection is at most a few hundred thousand vectors, which this scores in milliseconds,
/// so there's no approximate index to tune or rebuild.
public final class VectorIndex: Sendable {
    public let dimension: Int

    private struct Storage {
        var ids: [Int64] = []
        var kinds: [UnitKind] = []
        var vectors: [Float16] = []
        var rows: [Int64: Int] = [:]
    }

    private let storage = Mutex(Storage())

    public init(dimension: Int) {
        self.dimension = dimension
    }

    public var count: Int { storage.withLock { $0.ids.count } }

    /// Adds or replaces a vector.
    public func upsert(id: Int64, kind: UnitKind, vector: [Float]) {
        upsert(id: id, kind: kind, halves: vector.map { Float16($0) })
    }

    public func upsert(id: Int64, kind: UnitKind, halves: [Float16]) {
        precondition(halves.count == dimension, "vector has \(halves.count) values, index expects \(dimension)")
        storage.withLock { storage in
            if let row = storage.rows[id] {
                storage.kinds[row] = kind
                let start = row * dimension
                storage.vectors.replaceSubrange(start..<(start + dimension), with: halves)
            } else {
                storage.rows[id] = storage.ids.count
                storage.ids.append(id)
                storage.kinds.append(kind)
                storage.vectors.append(contentsOf: halves)
            }
        }
    }

    /// Removes vectors by moving the last row into each freed slot.
    public func remove(ids: [Int64]) {
        storage.withLock { storage in
            for id in ids {
                guard let row = storage.rows.removeValue(forKey: id) else { continue }
                let last = storage.ids.count - 1
                if row != last {
                    let movedID = storage.ids[last]
                    storage.ids[row] = movedID
                    storage.kinds[row] = storage.kinds[last]
                    let from = last * dimension
                    let to = row * dimension
                    for offset in 0..<dimension { storage.vectors[to + offset] = storage.vectors[from + offset] }
                    storage.rows[movedID] = row
                }
                storage.ids.removeLast()
                storage.kinds.removeLast()
                storage.vectors.removeLast(dimension)
            }
        }
    }

    public func removeAll() {
        storage.withLock { $0 = Storage() }
    }

    public struct Hit: Sendable, Hashable {
        public let id: Int64
        public let score: Float
    }

    /// The `limit` most similar vectors of one kind, best first.
    public func search(_ query: [Float], kind: UnitKind, limit: Int) -> [Hit] {
        precondition(query.count == dimension)
        guard limit > 0 else { return [] }
        return storage.withLock { storage -> [Hit] in
            let rowCount = storage.ids.count
            guard rowCount > 0 else { return [] }
            let chunkRows = 4_096
            let chunkCount = (rowCount + chunkRows - 1) / chunkRows
            let dimension = self.dimension
            let partials = Partials(count: chunkCount)

            storage.vectors.withUnsafeBufferPointer { vectors in
                storage.kinds.withUnsafeBufferPointer { kinds in
                    nonisolated(unsafe) let vectors = vectors
                    nonisolated(unsafe) let kinds = kinds
                    DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                        let firstRow = chunk * chunkRows
                        let rows = min(chunkRows, rowCount - firstRow)
                        var floats = [Float](repeating: 0, count: rows * dimension)
                        let base = firstRow * dimension
                        for index in 0..<(rows * dimension) { floats[index] = Float(vectors[base + index]) }
                        var scores = [Float](repeating: 0, count: rows)
                        // scores (rows×1) = floats (rows×dimension) · query (dimension×1)
                        vDSP_mmul(floats, 1, query, 1, &scores, 1, vDSP_Length(rows), 1, vDSP_Length(dimension))
                        var top = TopK(limit: limit)
                        for row in 0..<rows where kinds[firstRow + row] == kind {
                            top.insert(row: firstRow + row, score: scores[row])
                        }
                        partials.set(chunk, top)
                    }
                }
            }

            var merged = TopK(limit: limit)
            for top in partials.all { for entry in top.entries { merged.insert(row: entry.row, score: entry.score) } }
            return merged.sorted.map { Hit(id: storage.ids[$0.row], score: $0.score) }
        }
    }
}

/// Per-chunk results written from concurrent workers, each to its own slot.
private final class Partials: @unchecked Sendable {
    private var slots: [TopK?]
    private let lock = NSLock()

    init(count: Int) { slots = Array(repeating: nil, count: count) }

    func set(_ index: Int, _ top: TopK) {
        lock.lock()
        slots[index] = top
        lock.unlock()
    }

    var all: [TopK] { slots.compactMap { $0 } }
}

/// Keeps the highest-scoring `limit` rows seen, in a min-heap.
struct TopK {
    struct Entry { let row: Int; let score: Float }
    let limit: Int
    private(set) var entries: [Entry] = []

    init(limit: Int) {
        self.limit = limit
        entries.reserveCapacity(limit)
    }

    mutating func insert(row: Int, score: Float) {
        if entries.count < limit {
            entries.append(Entry(row: row, score: score))
            siftUp(entries.count - 1)
        } else if let smallest = entries.first, score > smallest.score {
            entries[0] = Entry(row: row, score: score)
            siftDown(0)
        }
    }

    var sorted: [Entry] { entries.sorted { $0.score > $1.score } }

    private mutating func siftUp(_ index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard entries[child].score < entries[parent].score else { return }
            entries.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(_ index: Int) {
        var parent = index
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var smallest = parent
            if left < entries.count, entries[left].score < entries[smallest].score { smallest = left }
            if right < entries.count, entries[right].score < entries[smallest].score { smallest = right }
            guard smallest != parent else { return }
            entries.swapAt(parent, smallest)
            parent = smallest
        }
    }
}
