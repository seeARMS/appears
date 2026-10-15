import AppearsCore
import Foundation
import Testing

@testable import GemmaEmbedder

/// `mac/Models/appears-model` in this checkout, made by `mac/scripts/fetch-model.sh`.
enum ModelFolder {
    static let url: URL = {
        if let path = ProcessInfo.processInfo.environment["APPEARS_MODEL"] { return URL(filePath: path) }
        var url = URL(filePath: #filePath)
        while url.path != "/" {
            url.deleteLastPathComponent()
            let candidate = url.appending(path: "mac/Models/appears-model")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return URL(filePath: "mac/Models/appears-model")
    }()

    static var exists: Bool {
        FileManager.default.fileExists(atPath: url.appending(path: "vision.safetensors").path)
    }
}

/// Vectors from Google's implementation (sentence-transformers, PyTorch, CPU float32),
/// written by `mac/scripts/reference_vectors.py`.
struct Reference: Decodable {
    struct Text: Decodable { let input: String; let vector: [Float] }
    let dimension: Int
    let texts: [Text]

    static func load() throws -> Reference {
        let url = try #require(Bundle.module.url(forResource: "reference-vectors", withExtension: "json"))
        return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }
}

func cosine(_ a: [Float], _ b: [Float]) -> Float {
    let dot = zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    let norms = (a.reduce(0) { $0 + $1 * $1 } * b.reduce(0) { $0 + $1 * $1 }).squareRoot()
    return dot / norms
}

@Suite(.enabled(if: ModelFolder.exists, "Run mac/scripts/fetch-model.sh first"), .serialized)
struct GemmaEmbedderTests {
    @Test func matchesReferenceText() async throws {
        let reference = try Reference.load()
        let embedder = try await GemmaEmbedder.load(from: ModelFolder.url)
        #expect(embedder.dimension == reference.dimension)
        let vectors = try await embedder.embed(formatted: reference.texts.map(\.input))
        for (vector, expected) in zip(vectors, reference.texts) {
            // bf16 weights against a float32 reference.
            #expect(cosine(vector, expected.vector) >= 0.995, "\(expected.input.prefix(60))")
        }
    }

    @Test func relatedTextIsCloser() async throws {
        let embedder = try await GemmaEmbedder.load(from: ModelFolder.url)
        let query = try await embedder.embed(queries: ["Re: kitchen remodel quote from the contractor"])[0]
        let documents = try await embedder.embed(documents: [
            EmbeddingDocument(title: "Quote", text: "Cabinets, countertops and labor for the kitchen: $18,400"),
            EmbeddingDocument(title: "Trip", text: "Our itinerary for three days hiking in Zion"),
        ])
        #expect(cosine(query, documents[0]) > cosine(query, documents[1]))
    }
}
