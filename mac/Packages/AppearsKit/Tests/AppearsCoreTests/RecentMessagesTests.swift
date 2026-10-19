import Foundation
import Testing
@testable import AppearsCore

@Suite struct RecentMessagesTests {
    @Test func ageNeverDemotesAnAnswerAndOnlyTheDraftDecides() async throws {
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
        let context = ContextSnapshot(appName: "Messages", windowTitle: "Jordan Vale", focusedText: text,
                                      visibleText: "Jordan: Want to walk around the lake on Saturday?")
        // Discovery: the same words two days or a hundred days old score the same.
        let undecided = try await Recall(store: store, vectors: vectors, embedder: embedder)
            .run(RecallRequest(context: context, trigger: .pull), now: now)
        let recent = try #require(undecided.suggestions.first { $0.item.path == "messages:0" })
        let old = try #require(undecided.suggestions.first { $0.item.path == "messages:1" })
        #expect(recent.score == old.score, "Age cannot demote equally relevant answers to an active question")

        // The decision reads the same text once (identical copies are one candidate) and its
        // probability lets the answer signal, the same for an ambient lookup as for an ask.
        let recall = Recall(store: store, vectors: vectors, embedder: embedder,
                            decider: ScriptedDecider.picking("Harbor Oaks", probability: 0.9))
        let ambient = try await recall.run(RecallRequest(context: context, trigger: .ambient), now: now)
        #expect(ambient.suggestions.filter { $0.item.title == "Jordan Vale" }.count == 1)
        #expect(SurfacePolicy().signalable(ambient.suggestions).first?.item.title == "Jordan Vale")
        let pull = try await recall.run(RecallRequest(context: context, trigger: .pull), now: now)
        #expect(pull.suggestions.map(\.confidence) == ambient.suggestions.map(\.confidence))

        // The chat name and old visible text must not turn the rent message into an
        // answer to a new, unrelated draft in that same conversation: the decision reads
        // the draft as the question, and the screen only as where the person is.
        let unrelated = ContextSnapshot(appName: "Messages", windowTitle: "Jordan Vale",
                                         focusedText: "Have you picked a movie for tonight?", visibleText: text)
        let decider = ScriptedDecider.picking("Harbor Oaks")
        let checking = Recall(store: store, vectors: vectors, embedder: embedder, decider: decider)
        _ = try await checking.run(RecallRequest(context: unrelated, trigger: .ambient), now: now)
        let asked = try #require(decider.requests.first)
        #expect(asked.question.contains("Have you picked a movie for tonight?"))
        #expect(!asked.record.contains("Harbor Oaks") && !asked.question.contains("Harbor Oaks"))
    }
}
