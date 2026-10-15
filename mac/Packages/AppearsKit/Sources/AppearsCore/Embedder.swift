import CoreGraphics
import Foundation

/// A title and text to embed as a search document.
public struct EmbeddingDocument: Sendable, Hashable {
    public let title: String
    public let text: String

    public init(title: String, text: String) {
        self.title = title
        self.text = text
    }
}

/// Turns queries, documents and images into vectors in one shared space.
///
/// Implementations return L2-normalized vectors of `dimension` floats, so a dot product is
/// cosine similarity. The real one is EmbeddingGemma 2 on MLX; `HashingEmbedder` stands in
/// for tests and for trying the pipeline without the model.
public protocol Embedder: Sendable {
    /// Names the model and its settings. Changing it makes the index re-embed everything.
    var modelID: String { get }
    var dimension: Int { get }
    /// Whether `embed(images:)` works. Without it, image units are embedded from their OCR text.
    var supportsImages: Bool { get }

    func embed(queries: [String]) async throws -> [[Float]]
    func embed(documents: [EmbeddingDocument]) async throws -> [[Float]]
    func embed(images: [CGImage]) async throws -> [[Float]]
}

/// EmbeddingGemma 2's task prompts, from its model card. Images take no prefix.
public enum EmbeddingGemmaPrompt {
    public static func query(_ text: String) -> String {
        "task: search result | query: \(text)"
    }

    public static func document(_ document: EmbeddingDocument) -> String {
        let title = document.title.isEmpty ? "none" : document.title
        return "title: \(title) | text: \(document.text)"
    }
}

enum VectorMath {
    static func normalized(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }
}
