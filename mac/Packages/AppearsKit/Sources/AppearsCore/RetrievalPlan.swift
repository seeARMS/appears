import Foundation

/// The active question and the surrounding screen have different jobs. Context can
/// discover evidence, but only the active question can establish its relevance.
struct RetrievalPlan {
    let primary: ContextSnapshot
    let surrounding: ContextSnapshot?
    let hasActiveText: Bool

    init(_ context: ContextSnapshot) {
        let selection = QueryBuilder.clean(context.selection)
        let draft = QueryBuilder.clean(context.focusedText)
        // A selection is explicit intent, including a short name or identifier.
        // The minimum length applies only to an automatically observed draft.
        let active = selection.isEmpty ? draft : selection
        hasActiveText = !selection.isEmpty || draft.count >= 12 || (context.origin == .text && !draft.isEmpty)
        if hasActiveText {
            primary = ContextSnapshot(appName: context.appName, selection: active, origin: context.origin)
            surrounding = ContextSnapshot(appName: context.appName, windowTitle: context.windowTitle,
                                          visibleText: context.visibleText, recipients: context.recipients)
        } else {
            primary = context
            surrounding = nil
        }
    }
}

/// Lexical relevance complements the encoder. No grammatical class, minimum word
/// length or corpus-frequency threshold can erase an explicitly supplied qualifier.
struct LexicalTerms {
    let terms: [String]
    let weights: [String: Double]

    init(_ text: String, store: IndexStore) throws {
        terms = Array(Self.tokens(text).filter { !Self.filler.contains($0) }.prefix(32))
        let frequencies = try store.documentFrequencies(terms)
        weights = Dictionary(uniqueKeysWithValues: terms.map {
            ($0, log(2 + Double(frequencies.total + 1) / Double((frequencies.counts[$0] ?? 0) + 1)))
        })
    }

    var fullText: String { terms.map { "\"\($0)\"" }.joined(separator: " OR ") }

    /// Preserve word order even when the platform's entity tagger misses a lowercase
    /// place or project name. Phrases discover candidates; they never assert an identity.
    var phraseQuery: String {
        var phrases: [String] = []
        for length in [3, 2] where terms.count >= length {
            for start in 0...(terms.count - length) {
                phrases.append("\"" + terms[start..<(start + length)].joined(separator: " ") + "\"")
            }
        }
        return phrases.prefix(32).joined(separator: " OR ")
    }

    func coverage(_ text: String) -> Double {
        let found = Set(Self.tokens(text))
        return terms.filter(found.contains).reduce(0) { $0 + (weights[$1] ?? 0) }
            / max(weights.values.reduce(0, +), 1)
    }

    static func tokens(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var seen = Set<String>()
        return folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { seen.insert($0).inserted }
    }

    static let filler: Set<String> = [
        "a", "an", "the", "and", "or", "of", "to", "for", "in", "on", "at", "by", "with",
        "i", "me", "my", "we", "our", "you", "your", "he", "she", "it", "its", "they", "their",
        "is", "are", "was", "were", "be", "been", "do", "does", "did", "have", "has", "had",
        "what", "which", "who", "when", "where", "how", "can", "could", "would", "please",
        "s", "t", "m", "ve", "re", "ll", "d",
        "much", "many", "any", "there", "this", "that", "from", "about", "anything",
    ]
}

/// Diagnostics are transient and contain only local identities/counts, never context.
/// They are used by the eval to distinguish retrieval loss from ranking loss.
public struct RetrievalDiagnostics: Sendable, Codable {
    public var candidateItemIDs: [Int64]
    public var shortlistedItemIDs: [Int64]
    public var rankedItemIDs: [Int64]? = nil
    public var refinedItemIDs: [Int64]? = nil
}
