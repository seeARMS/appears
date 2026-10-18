import AppearsCore
import ArgumentParser
import Foundation

/// Larger independent corpus: split discussions, repeated keyword matches, and distractors.
/// Source files are fictional; this evaluator never opens personal Messages.
func evaluateRetrieval(demo: URL, home: URL, embedder: any Embedder, threshold: Double, verbose: Bool) async throws {
    struct Scenario: Decodable {
        var name: String
        var title: String
        var focused: String
        var visible: String
        var chatIDs: [Int64]?
        var expect: [String]
        var quote: String?
        var silent: Bool?
        var rejectQuotes: [String]?
        var first: String?
    }
    struct Suite: Decodable { var retrieval: [Scenario]? }
    let scenarios = try JSONDecoder().decode(Suite.self, from: Data(contentsOf: demo.appending(path: "scenarios.json"))).retrieval ?? []
    guard !scenarios.isEmpty else { throw ValidationError("No retrieval scenarios found in scenarios.json.") }
    let store = try IndexStore(url: home.appending(path: ".retrieval/index.sqlite"))
    let vectors = VectorIndex(dimension: embedder.dimension)
    let messages = try JSONDecoder().decode([Eval.DemoMessage].self, from: Data(contentsOf: demo.appending(path: "retrieval-messages.json")))
    let now = Date()
    for start in stride(from: 0, to: messages.count, by: 8) {
        let batch = Array(messages[start..<min(start + 8, messages.count)])
        let embedded = try await embedder.embed(documents: batch.map { EmbeddingDocument(title: $0.title, text: $0.text) })
        for (offset, message) in batch.enumerated() {
            let date = now.addingTimeInterval(-message.age * 86_400)
            let reference = MessageReference(rowID: Int64(start + offset + 1), guid: message.path, chatID: message.chatID ?? 0, conversationURL: nil)
            let item = Item(source: .messages, path: message.path, kind: message.imageOCR == true ? .image : .message, title: message.title,
                            size: Int64(message.text.utf8.count), created: date, modified: date, lastUsed: nil, message: reference)
            let (id, _) = try store.record(item, signature: "demo")
            let update = try store.replaceUnits(itemID: id, title: message.title, units: [(Unit(kind: .text, locator: .whole, text: message.text), embedded[offset])])
            for unit in update.added { vectors.upsert(id: unit.id, kind: unit.kind, vector: embedded[offset]) }
        }
    }
    let recall = Recall(store: store, vectors: vectors, embedder: embedder)
    var failures = 0
    for scenario in scenarios {
        var context = ContextSnapshot(appName: "Messages", windowTitle: scenario.title, focusedText: scenario.focused, visibleText: scenario.visible)
        context.messageChatIDs = scenario.chatIDs
        let response = try await recall.run(RecallRequest(context: context, trigger: scenario.silent == true ? .ambient : .pull, limit: 10))
        let paths = response.suggestions.prefix(3).map { $0.item.path }
        let expectedIDs = try scenario.expect.compactMap { try store.item(path: $0)?.id }
        if let diagnostics = response.retrieval {
            print("    candidates \(expectedIDs.filter { diagnostics.candidateItemIDs.contains($0) }.count)/\(expectedIDs.count), shortlist \(expectedIDs.filter { diagnostics.shortlistedItemIDs.contains($0) }.count)/\(expectedIDs.count)")
        }
        let passed: Bool
        if scenario.silent == true {
            passed = !response.suggestions.prefix(3).contains { $0.ambientEligible != false && $0.confidence >= threshold }
        } else {
            passed = scenario.expect.allSatisfy(paths.contains)
                && (scenario.first.map { paths.first == $0 } ?? true)
                && !(scenario.rejectQuotes ?? []).contains { rejected in response.suggestions.prefix(3).contains {
                    ($0.evidence?.text ?? $0.snippet).localizedCaseInsensitiveContains(rejected)
                } }
                && (scenario.quote.map { quote in response.suggestions.prefix(3).contains {
                    scenario.expect.contains($0.item.path) && $0.evidence?.text.contains(quote) == true
                } } ?? true)
        }
        if !passed { failures += 1 }
        print("\(passed ? "✓" : "✗") retrieval: \(scenario.name) (\(Int(response.milliseconds)) ms)")
        if verbose || !passed {
            for result in response.suggestions.prefix(10) {
                print("    \(result.item.path) \(String(format: "%.3f", result.confidence)) score \(String(format: "%.3f", result.score)) cosine \(String(format: "%.3f", result.evidence?.cosine ?? 0)) \(result.evidence?.text ?? result.snippet)")
            }
        }
    }
    print("retrieval scenarios \(scenarios.count - failures)/\(scenarios.count)")
    if failures > 0 { throw ValidationError("Retrieval evaluation failed: \(failures) scenarios.") }
}
