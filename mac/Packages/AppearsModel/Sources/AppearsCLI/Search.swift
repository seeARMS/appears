import AppearsCore
import ArgumentParser
import Foundation
import GemmaEmbedder

/// Exercise precisely the typed-search path, read-only, without starting an indexer or
/// opening the journal. JSON goes only to the caller's stdout; no search text is logged.
struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "search", abstract: "Search the app's index by meaning and words, read-only.")
    @Option(help: "The folder containing index.sqlite (default: the app's index).")
    var data: String = MCP.appData + "/Appears"
    @Option(help: "A local model folder; otherwise use the app's verified model.")
    var model: String?
    @Option(help: "Results per query, up to 20.")
    var limit = 20
    @Flag(help: "Return one RecallResponse JSON object per query on stdout.")
    var json = false
    @Flag(help: "Use indexed discussion context only, without reading Messages.")
    var indexedContext = false
    @Argument(help: "One or more quoted search queries.")
    var text: [String]

    func run() async throws {
        guard !text.isEmpty else { throw ValidationError("Give at least one search query.") }
        let store = try IndexStore(url: URL(filePath: data).appending(path: "index.sqlite"), readOnly: true)
        let embedder = try await GemmaEmbedder.load(from: Common.modelFolder(model))
        guard try store.meta("model_id") == embedder.modelID else {
            throw ValidationError("The model does not match the index; pass the model used to build it.")
        }
        let vectors = VectorIndex(dimension: embedder.dimension)
        try store.loadVectors(into: vectors)
        let sources = UserDefaults(suiteName: "rs.appea.appears")?.data(forKey: "sources")
            .flatMap { try? JSONDecoder().decode(SourceSettings.self, from: $0) } ?? SourceSettings()
        let search = Search(recall: Recall(store: store, vectors: vectors, embedder: embedder),
                            messages: indexedContext ? nil : MessagesReader())
        for query in text {
            let response = try await search.run(SearchRequest(text: query, limit: limit), sources: sources)
            if json {
                print(String(decoding: try JSONEncoder().encode(response), as: UTF8.self))
            } else {
                print("\(response.suggestions.count) results in \(Int(response.milliseconds)) ms")
                for (index, result) in response.suggestions.enumerated() {
                    print("\(index + 1). \(result.item.title) · \(result.reason)")
                    print("   \(result.snippet)")
                }
            }
        }
    }
}
