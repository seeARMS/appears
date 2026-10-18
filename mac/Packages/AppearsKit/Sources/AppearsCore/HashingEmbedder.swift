import CoreGraphics
import Foundation

/// A stand-in embedder that hashes words and word pairs into a vector. It matches shared
/// words, not meaning, and can't see images. Tests use it because it's deterministic and
/// instant; `appears --embedder hash` uses it to try the pipeline without the model.
public struct HashingEmbedder: Embedder {
    public let dimension: Int
    public var modelID: String { "hashing-\(dimension)" }
    public var supportsImages: Bool { false }
    public var supportsSemanticSimilarity: Bool { false }

    public init(dimension: Int = 256) {
        self.dimension = dimension
    }

    public func embed(queries: [String]) async throws -> [[Float]] {
        queries.map(vector)
    }

    public func embed(documents: [EmbeddingDocument]) async throws -> [[Float]] {
        documents.map { vector("\($0.title) \($0.text)") }
    }

    public func embed(images: [CGImage]) async throws -> [[Float]] {
        images.map { _ in [Float](repeating: 0, count: dimension) }
    }

    private static let stopwords: Set<String> = [
        "a", "an", "and", "are", "at", "be", "for", "from", "i", "in", "is", "it", "me", "my", "of",
        "on", "or", "that", "the", "this", "to", "was", "with", "you", "your", "task", "query",
        "search", "result", "title", "text", "none",
    ]

    func vector(_ text: String) -> [Float] {
        let words = text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map { Self.stem(String($0)) }
            .filter { !Self.stopwords.contains($0) }
        var vector = [Float](repeating: 0, count: dimension)
        func add(_ feature: String, weight: Float) {
            let hash = Self.fnv1a(feature)
            let index = Int(hash % UInt64(dimension))
            vector[index] += (hash >> 63) == 0 ? weight : -weight
        }
        for word in words { add(word, weight: 1) }
        for (first, second) in zip(words, words.dropFirst()) { add("\(first) \(second)", weight: 0.5) }
        return VectorMath.normalized(vector)
    }

    /// Strips a few common English endings so "parking" matches "park".
    private static func stem(_ word: String) -> String {
        for suffix in ["ing", "ed", "es", "s"] where word.count > suffix.count + 2 && word.hasSuffix(suffix) {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    private static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return hash
    }
}
