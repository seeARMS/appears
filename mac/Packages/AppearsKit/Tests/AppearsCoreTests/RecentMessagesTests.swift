import Foundation
import Testing
@testable import AppearsCore

@Suite struct RecentMessagesTests {
    @Test func recentMessagesCanSurfaceWithASmallRankingPenalty() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "appears-recent-messages-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try IndexStore(url: folder.appending(path: "index.sqlite"))
        let embedder = HashingEmbedder()
        let vectors = VectorIndex(dimension: embedder.dimension)
        let now = Date()
        let text = "Jordan Vale paid the final Harbor Oaks apartment rent bill. The balance is zero."
        for number in 0..<42 {
            let age = number == 0 ? 2.0 : 100.0
            let date = now.addingTimeInterval(-age * 86_400)
            let relevant = number < 2
            let title = relevant ? "Jordan Vale" : "Other conversation \(number)"
            let words = relevant ? text : "Telescope observatory astronomy constellation \(number)"
            let item = Item(source: .messages, path: "messages:\(number)", kind: .message, title: title,
                            size: Int64(words.count), created: date, modified: date, lastUsed: nil)
            let (id, _) = try store.record(item, signature: "test")
            let vector = try await embedder.embed(documents: [EmbeddingDocument(title: title, text: words)])[0]
            let update = try store.replaceUnits(itemID: id, title: title, units: [
                (AppearsCore.Unit(kind: .text, locator: .whole, text: words), vector),
            ])
            for unit in update.added { vectors.upsert(id: unit.id, kind: unit.kind, vector: vector) }
        }
        let recall = Recall(store: store, vectors: vectors, embedder: embedder)
        let context = ContextSnapshot(appName: "Messages", windowTitle: "Jordan Vale", focusedText: text,
                                      visibleText: "Jordan: Want to walk around the lake on Saturday?")
        let ambient = try await recall.run(RecallRequest(context: context, trigger: .ambient), now: now)
        let recent = try #require(ambient.suggestions.first { $0.item.path == "messages:0" })
        let old = try #require(ambient.suggestions.first { $0.item.path == "messages:1" })
        #expect(recent.confidence >= SurfacePolicy.Settings().threshold)
        #expect(recent.score < old.score)
        #expect(recent.score > old.score * 0.8)
        let pull = try await recall.run(RecallRequest(context: context, trigger: .pull), now: now)
        let pulled = try #require(pull.suggestions.first { $0.item.path == "messages:0" })
        #expect(recent.confidence == pulled.confidence)

        // The chat name and old visible text must not turn the rent message into an
        // answer to a new, unrelated draft in that same conversation.
        let unrelated = ContextSnapshot(appName: "Messages", windowTitle: "Jordan Vale",
                                         focusedText: "Have you picked a movie for tonight?", visibleText: text)
        let other = try await recall.run(RecallRequest(context: unrelated, trigger: .ambient), now: now)
        #expect(!other.suggestions.contains { $0.item.path == "messages:0" && $0.confidence >= SurfacePolicy.Settings().threshold })
    }
}
