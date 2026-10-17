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

/// CPU-prepared pixels bound to their embedder. Calling `vector()` performs the model
/// work; preparation itself must neither load model weights nor run a model forward.
public struct PreparedImageEmbedding: Sendable {
    private let operation: @Sendable () async throws -> [Float]

    public init(_ operation: @escaping @Sendable () async throws -> [Float]) {
        self.operation = operation
    }

    public func vector() async throws -> [Float] { try await operation() }
}

/// Turns queries, documents and images into vectors in one shared space.
///
/// Implementations return L2-normalized vectors of `dimension` floats, so a dot product is
/// cosine similarity. The real one is EmbeddingGemma 2 on MLX; `HashingEmbedder` stands in
/// for tests and for trying the pipeline without the model.
public protocol Embedder: Sendable {
    /// Stored-document-vector lookups keep their already-scored indexed units; they
    /// cannot refine passages as though the vector represented a free-text question.
    var supportsPassageRefinement: Bool { get }
    /// Names the model and its settings. Changing it makes the index re-embed everything.
    var modelID: String { get }
    var dimension: Int { get }
    /// Whether `embed(images:)` works. Without it, image units are embedded from their OCR text.
    var supportsImages: Bool { get }

    func embed(queries: [String]) async throws -> [[Float]]
    func embed(documents: [EmbeddingDocument]) async throws -> [[Float]]
    /// Source passages being scored for an active lookup, ahead of background indexing.
    func embed(passages: [EmbeddingDocument]) async throws -> [[Float]]
    func embed(images: [CGImage]) async throws -> [[Float]]
    func prepare(image: CGImage) throws -> PreparedImageEmbedding
}

extension Embedder {
    public var supportsPassageRefinement: Bool { true }
    public func embed(passages: [EmbeddingDocument]) async throws -> [[Float]] {
        try await embed(documents: passages)
    }

    public func prepare(image: CGImage) throws -> PreparedImageEmbedding {
        PreparedImageEmbedding { try await self.embed(images: [image])[0] }
    }
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
