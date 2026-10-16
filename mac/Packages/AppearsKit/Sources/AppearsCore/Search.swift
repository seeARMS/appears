import Foundation

/// An explicit question, separate from screen context and the suggestion journal.
public struct SearchRequest: Sendable, Codable {
    public var text: String
    public var limit: Int
    public var token: SearchToken?

    public init(text: String, limit: Int = 20, token: SearchToken? = nil) {
        self.text = text
        self.limit = limit
        self.token = token
    }
}

/// Searches the same text and image embeddings as recall, with exact-name matching too.
/// Recent items count fully when the user asks for something explicitly. Queries and
/// results are never journaled; source exclusions and "Never show this" still apply.
public struct Search: Sendable {
    public let recall: Recall

    public init(recall: Recall) { self.recall = recall }

    public func run(_ request: SearchRequest, sources: SourceSettings, now: Date = Date()) async throws -> RecallResponse {
        try Task.checkCancellation()
        let prepared = ContinuousClock.now
        let text = String(request.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000))
        guard !text.isEmpty else {
            return RecallResponse(suggestions: [], query: .init(entities: [], rareTerms: [], denseCharacters: 0), milliseconds: 0)
        }
        var excluded = try recall.store.itemIDs(under: sources.excludes)
        excluded += try recall.store.itemIDs(kinds: sources.excludedKinds)
        if !sources.notes { excluded += try recall.store.itemIDs(source: .notes) }
        if !sources.messages { excluded += try recall.store.itemIDs(source: .messages) }
        SearchTrace.current?.record(.preparation, since: prepared)
        try Task.checkCancellation()
        var recall = recall
        recall.settings.recentWeight = 1
        recall.settings.recentMessageWeight = 1
        recall.settings.olderWeight = 1
        // Explicit search orders by relevance. Ambient diversity can otherwise promote an
        // unrelated item ahead of a second close match (especially a photo of the same thing).
        recall.settings.diversity = 1
        // A short selection otherwise doesn't reach the dense query. Keep one-word searches
        // ("Lisbon", "wifi") useful without changing how screen contexts are interpreted.
        let context = ContextSnapshot(selection: QueryBuilder.clean(text).count < 12 ? "Anything about \(text)" : text, origin: .text)
        return try await recall.run(
            RecallRequest(context: context, trigger: .pull, limit: min(max(request.limit, 1), 20), exclude: excluded),
            now: now, groupMessageConversations: true
        )
    }
}
