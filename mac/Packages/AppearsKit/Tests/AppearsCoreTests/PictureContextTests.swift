import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AppearsCore

/// Words point one way and pictures another, so a test can tell which one found a result.
private struct PictureTestEmbedder: Embedder {
    let modelID = "picture-test"
    let dimension = 3
    var supportsImages = true
    func embed(queries: [String]) async throws -> [[Float]] { queries.map { _ in [1, 0, 0] } }
    func embed(documents: [EmbeddingDocument]) async throws -> [[Float]] { documents.map { _ in [1, 0, 0] } }
    func embed(images: [CGImage]) async throws -> [[Float]] { images.map { _ in [0, 0, 1] } }
}

@Suite struct PictureContextTests {
    private func engine(supportsImages: Bool = true) throws -> (Engine, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "appears-picture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "Pictures"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appending(path: "Notes"), withIntermediateDirectories: true)
        let embedder = PictureTestEmbedder(supportsImages: supportsImages)
        return (try Engine(folder: folder, embedder: embedder, settings: SourceSettings()), folder)
    }

    @discardableResult
    private func add(_ engine: Engine, path: String, kind: ItemKind, vector: [Float], age: Double = 400) throws -> Int64 {
        let date = Date().addingTimeInterval(-age * 86_400)
        let item = Item(source: .file, path: path, kind: kind, title: (path as NSString).lastPathComponent,
                        size: 1, created: date, modified: date, lastUsed: nil)
        let (id, _) = try engine.store.record(item, signature: "test")
        let units = try engine.store.replaceUnits(itemID: id, title: item.title, units: [
            (AppearsCore.Unit(kind: kind == .image ? .image : .text, locator: .whole, text: "a pothos with yellow leaves"), vector),
        ]).added
        for unit in units { engine.vectors.upsert(id: unit.id, kind: unit.kind, vector: vector) }
        return id
    }

    private func preview(_ path: String) -> ContextSnapshot {
        ContextSnapshot(appName: "Preview", bundleID: "com.apple.Preview", windowTitle: (path as NSString).lastPathComponent,
                        documentPath: path, origin: .accessibility)
    }

    /// A plain 400×300 PNG, enough for the image loader.
    private func writePicture(to url: URL) throws {
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func showsPictureOnlyForImageDocuments() {
        #expect(preview("/Users/me/Desktop/IMG_2041.HEIC").showsPicture)
        #expect(!preview("/Users/me/Documents/notes.md").showsPicture)
        #expect(!ContextSnapshot.text("hello").showsPicture)
    }

    @Test func fileNameTitlesAreRecognized() {
        #expect(Recall.isFileName("IMG_2041.HEIC", of: "/a/IMG_2041.HEIC", app: "Preview"))
        #expect(Recall.isFileName("IMG_2041", of: "/a/IMG_2041.HEIC", app: "Preview"))
        #expect(Recall.isFileName("", of: "/a/IMG_2041.HEIC", app: "Preview"))
        #expect(!Recall.isFileName("Our pothos, October", of: "/a/IMG_2041.HEIC", app: "Preview"))
    }

    @Test func anIndexedPictureSearchesWithItsStoredVector() async throws {
        let (engine, folder) = try engine()
        defer { try? FileManager.default.removeItem(at: folder) }
        let open = folder.appending(path: "IMG_2041.HEIC").path
        try add(engine, path: open, kind: .image, vector: [0, 1, 0], age: 0)
        let older = try add(engine, path: folder.appending(path: "Pictures/IMG_0412.HEIC").path, kind: .image, vector: [0, 1, 0])
        let words = try add(engine, path: folder.appending(path: "Notes/unrelated.md").path, kind: .document, vector: [1, 0, 0])
        let response = try await engine.recall.run(RecallRequest(context: preview(open), trigger: .pull, limit: 3))
        // The stored vector ([0, 1, 0]), not a fresh embedding ([0, 0, 1]) or the file name's words.
        #expect(response.suggestions.first?.id == older)
        #expect(response.suggestions.first?.features.cosine ?? 0 > 0.99)
        #expect(!response.suggestions.contains { $0.item.path == open })
        #expect(response.suggestions.first { $0.id == words }?.features.cosine ?? 0 < 0.01)
    }

    @Test func aPictureNotYetIndexedIsEmbeddedFromTheFile() async throws {
        let (engine, folder) = try engine()
        defer { try? FileManager.default.removeItem(at: folder) }
        let open = folder.appending(path: "new-photo.png")
        try writePicture(to: open)
        let match = try add(engine, path: folder.appending(path: "Pictures/IMG_0412.HEIC").path, kind: .image, vector: [0, 0, 1])
        try add(engine, path: folder.appending(path: "Notes/unrelated.md").path, kind: .document, vector: [1, 0, 0])
        let response = try await engine.recall.run(RecallRequest(context: preview(open.path), trigger: .pull, limit: 3))
        #expect(response.suggestions.first?.id == match)
        #expect(response.suggestions.first?.features.cosine ?? 0 > 0.99)
        // Staying on it uses the remembered vector.
        let again = try await engine.recall.run(RecallRequest(context: preview(open.path), trigger: .pull, limit: 3))
        #expect(again.suggestions.first?.id == match)
    }

    @Test func wordsInThePictureWindowAreBlendedIn() async throws {
        let (engine, folder) = try engine()
        defer { try? FileManager.default.removeItem(at: folder) }
        let open = folder.appending(path: "IMG_2041.HEIC").path
        try add(engine, path: open, kind: .image, vector: [0, 1, 0], age: 0)
        let picture = try add(engine, path: folder.appending(path: "Pictures/IMG_0412.HEIC").path, kind: .image, vector: [0, 1, 0])
        var context = preview(open)
        context.windowTitle = "Our pothos on the living room shelf"
        let response = try await engine.recall.run(RecallRequest(context: context, trigger: .pull, limit: 3))
        let cosine = response.suggestions.first { $0.id == picture }?.features.cosine ?? 0
        // Mostly the picture, partly the words.
        #expect(cosine > 0.8 && cosine < 0.99)
    }

    @Test func withoutAnImageModelOnlyTheWordsCount() async throws {
        let (engine, folder) = try engine(supportsImages: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let open = folder.appending(path: "IMG_2041.HEIC").path
        try add(engine, path: open, kind: .image, vector: [0, 1, 0], age: 0)
        try add(engine, path: folder.appending(path: "Pictures/IMG_0412.HEIC").path, kind: .image, vector: [0, 1, 0])
        let response = try await engine.recall.run(RecallRequest(context: preview(open), trigger: .pull, limit: 3))
        #expect(!response.suggestions.contains { $0.features.cosine > 0.5 })
    }
}
