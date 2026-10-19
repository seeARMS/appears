import CoreGraphics
import EmbeddingGemma2
import Foundation
import MLX
import AppearsCore

/// EmbeddingGemma 2 on this Mac's GPU, through MLX: queries, documents and images in one
/// 768-dimensional space.
///
/// Loads from a local folder prepared by `mac/scripts/prepare_model.py`, installed by
/// the separate downloader. The embedder and engine never download anything.
/// Never downloads anything.
public final class GemmaEmbedder: Embedder {
    public let modelID: String
    public let dimension: Int
    public var supportsImages: Bool { true }
    /// Soft tokens per image: 280 (default), 140 or 70. Fewer is faster and coarser.
    public let imageTokens: Int
    let encoder: TextEncoder
    /// Gemma's tokenizer, fast. Nil runs everything through swift-transformers' instead.
    let tokenizer: GemmaTokenizer?
    /// Where the weights live, so the vision tower can be loaded again after `unloadVision()`.
    let folder: URL
    private let visionState = VisionState()

    private struct Manifest: Decodable {
        let source_sha256: String
    }

    private init(encoder: TextEncoder, tokenizer: GemmaTokenizer?, folder: URL, modelID: String, dimension: Int, imageTokens: Int) {
        self.encoder = encoder
        self.folder = folder
        self.tokenizer = tokenizer
        self.modelID = modelID
        self.dimension = dimension
        self.imageTokens = imageTokens
    }

    /// The model folder bundled in the app: `Contents/Resources/appears-model`.
    public static var bundledModelFolder: URL? {
        Bundle.main.url(forResource: "appears-model", withExtension: nil)
    }

    /// MLX keeps freed GPU buffers for reuse, and by default it keeps up to its memory limit:
    /// 95% of the GPU's working set, about 36 GB on a 48 GB Mac. Each batch pads to a
    /// different length, so buffers rarely match and the cache only grows. A first index of
    /// a large history filled it, ran the Mac out of swap and stalled the app. 1 GB is plenty
    /// to reuse buffers between batches of the same shape.
    static let cacheLimit = 1 << 30

    public static func load(
        from folder: URL, dimension: Int = 768, imageTokens: Int = 280, fastTokenizer: Bool = true
    ) async throws -> GemmaEmbedder {
        Memory.cacheLimit = cacheLimit
        let encoder = try await TextEncoder(directory: folder)
        let tokenizer = fastTokenizer ? try GemmaTokenizer(contentsOf: folder.appending(path: "tokenizer.json")) : nil
        // The vision tower loads on the first image and unloads after indexing (`unloadVision`),
        // so the always-on engine keeps only the text encoder resident.
        let manifest = try? JSONDecoder().decode(
            Manifest.self, from: Data(contentsOf: folder.appending(path: "appears-model.json"))
        )
        let weights = manifest.map { String($0.source_sha256.prefix(8)) } ?? "local"
        return GemmaEmbedder(
            encoder: encoder,
            tokenizer: tokenizer,
            folder: folder,
            // "/hf": tokenized like Hugging Face. Indexes made with swift-transformers' BPE, which
            // splits emoji, accents and runs of spaces differently, re-embed.
            modelID: "embeddinggemma-2@\(weights)/d\(dimension)/i\(imageTokens)" + (fastTokenizer ? "/hf" : ""),
            dimension: dimension,
            imageTokens: imageTokens
        )
    }

    public func embed(queries: [String]) async throws -> [[Float]] {
        try await embed(formatted: queries.map(EmbeddingGemmaPrompt.query))
    }

    public func embed(documents: [EmbeddingDocument]) async throws -> [[Float]] {
        try await embed(formatted: documents.map(EmbeddingGemmaPrompt.document))
    }

    public func embed(images: [CGImage]) async throws -> [[Float]] {
        var vectors: [[Float]] = []
        for image in images {
            vectors.append(try await prepare(image: image).vector())
        }
        return vectors
    }

    public func prepare(image: CGImage) throws -> PreparedImageEmbedding {
        let pixels = try ImageProcessor.prepare(Self.opaqueRGB(image), maxSoftTokens: imageTokens)
        return PreparedImageEmbedding {
            if await self.visionState.markLoaded() {
                try await self.encoder.enableVision(directory: self.folder)
            }
            return try await self.encoder.encodeImage(pixels, dimensions: self.dimension)
        }
    }

    /// Token IDs for documents, as `embed(documents:)` would feed them to the model. For
    /// benchmarks and tests.
    public func tokenize(documents: [EmbeddingDocument]) async throws -> [[Int]] {
        try await tokenize(formatted: documents.map(EmbeddingGemmaPrompt.document))
    }

    /// Token IDs for text that already has its task prompt.
    public func tokenize(formatted texts: [String]) async throws -> [[Int]] {
        guard !texts.isEmpty else { return [] }
        guard let tokenizer else { return try await encoder.tokenize(texts, task: .raw) }
        var rows: [[Int]] = []
        rows.reserveCapacity(texts.count)
        for text in texts {
            if let ids = tokenizer.encode(text) {
                rows.append(ids)
            } else {
                rows += try await encoder.tokenize([text], task: .raw)
            }
        }
        guard rows.allSatisfy({ $0.count <= 8192 }) else { throw EmbeddingError.invalid("Text exceeds 8192 tokens") }
        return rows
    }

    /// Frees the vision tower (about 400 MB). The next image loads it again.
    public func unloadVision() async {
        guard await visionState.markUnloaded() else { return }
        await encoder.disableVision()
    }

    /// The most GPU memory MLX has used since launch.
    public var peakMemory: Int { Memory.peakMemory }

    /// Text that already has its task prompt.
    func embed(formatted texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let rows = try await tokenize(formatted: texts)
        let length = rows.map(\.count).max() ?? 0
        let ids = rows.map { $0 + Array(repeating: 0, count: length - $0.count) }
        let mask = rows.map { Array(repeating: 1, count: $0.count) + Array(repeating: 0, count: length - $0.count) }
        return try await encoder.encodeTokens(ids: ids, mask: mask, dimensions: dimension)
    }

    /// The encoder takes opaque sRGB pixels. Screenshots are often PNGs with an alpha
    /// channel, so draw onto white first.
    static func opaqueRGB(_ image: CGImage) throws -> RGBImage {
        let width = image.width
        let height = image.height
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { pixels -> Bool in
            guard let context = CGContext(
                data: pixels.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw EmbeddingError.invalid("Couldn't draw the image") }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for pixel in 0..<(width * height) {
            rgb[pixel * 3] = rgba[pixel * 4]
            rgb[pixel * 3 + 1] = rgba[pixel * 4 + 1]
            rgb[pixel * 3 + 2] = rgba[pixel * 4 + 2]
        }
        return try RGBImage(width: width, height: height, bytes: rgb)
    }
}

/// Whether the vision tower is loaded.
private actor VisionState {
    private var loaded = false
    /// True if it wasn't loaded (the caller loads it).
    func markLoaded() -> Bool { defer { loaded = true }; return !loaded }
    /// True if it was loaded (the caller unloads it).
    func markUnloaded() -> Bool { defer { loaded = false }; return loaded }
}

extension GemmaEmbedder: UnloadsVision {}
