import CoreGraphics
import Foundation
import Testing
@testable import AppearsCore

/// Known vectors let these tests prove the UI's search path uses embeddings even when
/// the question and the stored text have no words in common.
private struct SearchTestEmbedder: Embedder {
    let modelID = "search-test"
    let dimension = 3
    let supportsImages = true
    func embed(queries: [String]) async throws -> [[Float]] { queries.map { _ in [1, 0, 0] } }
    func embed(documents: [EmbeddingDocument]) async throws -> [[Float]] { documents.map { _ in [1, 0, 0] } }
    func embed(images: [CGImage]) async throws -> [[Float]] { images.map { _ in [1, 0, 0] } }
}

@Suite struct SearchTests {
    private func engine() throws -> (Engine, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "appears-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (try Engine(folder: folder, embedder: SearchTestEmbedder(), settings: SourceSettings()), folder)
    }

    @discardableResult
    private func add(_ engine: Engine, path: String, source: ItemSource = .file, kind: ItemKind = .document,
                     vector: [Float] = [1, 0, 0], age: Double = 0) throws -> Int64 {
        let date = Date().addingTimeInterval(-age * 86_400)
        let item = Item(source: source, path: path, kind: kind, title: (path as NSString).lastPathComponent,
                        size: 1, created: date, modified: date, lastUsed: nil)
        let (id, _) = try engine.store.record(item, signature: "test")
        let units = try engine.store.replaceUnits(itemID: id, title: item.title, units: [
            (AppearsCore.Unit(kind: kind == .image ? .image : .text, locator: .whole, text: "Ruiz cabinetry estimate"), vector),
        ]).added
        for unit in units { engine.vectors.upsert(id: unit.id, kind: unit.kind, vector: vector) }
        return id
    }

    @Test func semanticSearchIncludesRecentItemsAndImagesWithoutLexicalOverlap() async throws {
        let (engine, folder) = try engine()
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = try add(engine, path: folder.appending(path: "estimate.md").path)
        let image = try add(engine, path: folder.appending(path: "photo.jpg").path, kind: .image, age: 500)
        _ = try add(engine, path: folder.appending(path: "unrelated.md").path, vector: [0, 1, 0], age: 500)
        let payload = try JSONEncoder().encode(SearchRequest(text: "renovation budget", limit: 2))
        let response = try JSONDecoder().decode(RecallResponse.self, from: await engine.handle(.search, payload: payload))
        #expect(Set(response.suggestions.map(\.id)) == [document, image])
        #expect(response.suggestions.allSatisfy { $0.features.forgotten == 1 })
        #expect(response.suggestions.allSatisfy { !$0.features.entityHit })
        #expect(response.suggestions.contains { $0.features.daysSinceTouched < 1 })
        let stats = try engine.journal.stats(days: 7)
        #expect(stats.pulls == 0 && stats.ambient == 0 && stats.shadow == 0)
    }

    @Test func shortQueriesWorkAndAllExclusionsApply() async throws {
        let (engine, folder) = try engine()
        defer { try? FileManager.default.removeItem(at: folder) }
        let allowed = try add(engine, path: folder.appending(path: "allowed.md").path)
        _ = try add(engine, path: folder.appending(path: "excluded/private.md").path)
        _ = try add(engine, path: "notes:demo", source: .notes, kind: .note)
        _ = try add(engine, path: "messages:demo", source: .messages, kind: .message)
        _ = try add(engine, path: folder.appending(path: "excluded-kind.pdf").path, kind: .pdf)
        let blocked = try add(engine, path: folder.appending(path: "blocked.md").path)
        try engine.store.setNeverShow(itemID: blocked)
        let sources = SourceSettings(excludes: [folder.appending(path: "excluded").path], excludedKinds: [.pdf], notes: false, messages: false)
        let response = try await Search(recall: engine.recall).run(SearchRequest(text: "wifi"), sources: sources)
        #expect(response.query.denseCharacters >= 12)
        #expect(response.suggestions.map(\.id) == [allowed])
    }

    @Test func emptyQueriesReturnNothingAndLimitsAreBounded() async throws {
        let (engine, folder) = try engine()
        defer { try? FileManager.default.removeItem(at: folder) }
        for index in 0..<25 { try add(engine, path: folder.appending(path: "\(index).md").path) }
        let search = Search(recall: engine.recall)
        #expect(try await search.run(SearchRequest(text: " \n "), sources: SourceSettings()).suggestions.isEmpty)
        #expect(try await search.run(SearchRequest(text: "wifi", limit: 100), sources: SourceSettings()).suggestions.count == 20)
        #expect(try await search.run(SearchRequest(text: "wifi", limit: -1), sources: SourceSettings()).suggestions.count == 1)
    }
}
