import Foundation

/// Explicit searches already say what matters. Grammar and corpus frequency must not
/// silently remove a verb, qualifier, name or short amount from the lexical search.
struct SearchQuery {
    let text: String
    let terms: [String]
    let weights: [String: Double]

    init(_ text: String, store: IndexStore) throws {
        self.text = text
        terms = Array(Self.tokens(text).filter { !Self.filler.contains($0) }.prefix(32))
        let frequencies = try store.documentFrequencies(terms)
        weights = Dictionary(uniqueKeysWithValues: terms.map {
            ($0, 1 + log(1 + Double(frequencies.total + 1) / Double((frequencies.counts[$0] ?? 0) + 1)))
        })
    }

    var fullText: String { terms.map { "\"\($0.replacingOccurrences(of: "\"", with: " "))\"" }.joined(separator: " OR ") }
    var summary: Query.Summary { .init(entities: [], rareTerms: terms, denseCharacters: text.count) }

    func coverage(in text: String) -> Double {
        guard !terms.isEmpty else { return 0 }
        let words = Set(Self.tokens(text))
        let total = weights.values.reduce(0, +)
        return terms.reduce(0) { result, term in
            // FTS supplies stemmed matches. This independent signal rewards literal wording.
            let match = words.contains(term) ? 1.0 : 0
            return result + (weights[term] ?? 1) * match
        } / max(total, 1)
    }

    static func tokens(_ text: String) -> [String] {
        let text = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var seen = Set<String>()
        return text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // Small grammatical filler list, independent of part of speech. Negations, verbs,
    // adjectives, numbers and domain words remain searchable.
    static let filler: Set<String> = [
        "a", "an", "the", "and", "or", "of", "to", "for", "in", "on", "at", "by", "with",
        "i", "me", "my", "we", "our", "you", "your", "he", "she", "it", "its", "they", "their",
        "is", "are", "was", "were", "be", "been", "do", "does", "did", "have", "has", "had",
        "what", "which", "who", "when", "where", "how", "can", "could", "would", "please",
    ]
}
