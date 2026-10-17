import AppearsCore
import Foundation
import Testing
@testable import GemmaEmbedder

@Suite(.enabled(if: ModelFolder.exists, "Prepare the model before running inference tests"), .serialized)
struct PassageModelTests {
    @Test func paraphrasesSelectAndDisplayTheExactSourcePassage() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "appears-passages-model-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let embedder = try await GemmaEmbedder.load(from: ModelFolder.url)
        let store = try IndexStore(url: folder.appending(path: "index.sqlite"))
        let vectors = VectorIndex(dimension: embedder.dimension)
        let documents = [
            "Was this at your gate?\nYes, this morning.\nThe parcel courier said his relatives own Silverbrook Cellars in Oak Hollow.\nThey host complimentary tastings on the third Saturday of each month.\nYou can bring your own picnic.\nThe map screenshot was about a small vegetation fire nearby.",
            "Your wine shipment was delivered this morning. The tracking link shows that the parcel courier left the box at your gate.",
            "There is a small vegetation fire near the road. This map shows the affected area.",
        ]
        let embedded = try await embedder.embed(documents: documents.map { .init(title: "", text: $0) })
        let date = Date().addingTimeInterval(-120 * 86_400)
        for (number, text) in documents.enumerated() {
            let item = Item(source: .notes, path: "notes:demo-\(number)", kind: .note, title: "Conversation \(number)",
                            size: Int64(text.utf8.count), created: date, modified: date, lastUsed: nil)
            let (id, _) = try store.record(item, signature: "demo")
            let update = try store.replaceUnits(itemID: id, title: item.title, units: [
                (AppearsCore.Unit(kind: .text, locator: .whole, text: text), embedded[number]),
            ])
            for unit in update.added { vectors.upsert(id: unit.id, kind: unit.kind, vector: embedded[number]) }
        }
        let recall = Recall(store: store, vectors: vectors, embedder: embedder)
        for question in ["what was the winery the delivery guy mentioned?", "Which tasting room did the parcel carrier tell us about?"] {
            let response = try await recall.run(RecallRequest(context: ContextSnapshot(appName: "Messages", focusedText: question), trigger: .pull))
            let result = try #require(response.suggestions.first)
            #expect(result.item.path == "notes:demo-0")
            let evidence = try #require(result.evidence)
            #expect(evidence.text.contains("Silverbrook Cellars in Oak Hollow"))
            #expect(documents[0].contains(evidence.text))
            #expect(SuggestionEvidence(result, terms: ["gate"]).segments.map(\.text).joined() == evidence.text)
        }
    }
}
