import Foundation
import NaturalLanguage

/// Turns a context into what the engine searches with: a dense query (the most telling
/// text, for the embedding) and named entities and rare words (for full-text search, where
/// embeddings are weakest: names, numbers, addresses).
public struct Query: Sendable, Equatable {
    public var dense: String
    /// People, organizations and places, as written.
    public var entities: [String]
    /// Email addresses, phone numbers, street addresses, order and invoice numbers.
    public var identifiers: [String]
    /// Uncommon words in the index that appear in the context.
    public var rareTerms: [String]

    /// An FTS5 query that matches any of the entities, identifiers or rare terms.
    public var fullText: String {
        let phrases = (entities + identifiers + rareTerms)
            .map { $0.replacingOccurrences(of: "\"", with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 2 }
        return Array(Set(phrases)).sorted().map { "\"\($0)\"" }.joined(separator: " OR ")
    }

    /// Entities and identifiers, lowercased, for spotting them in a result.
    public var matchable: [String] {
        (entities + identifiers).map { $0.lowercased() }.filter { $0.count >= 3 }
    }
}

public enum QueryBuilder {
    /// Characters of context that go into the dense query (about 500 tokens).
    static let denseBudget = 2_000

    public static func build(_ context: ContextSnapshot, frequencies: ((([String]) -> (counts: [String: Int], total: Int))?) = nil) -> Query {
        let selection = clean(context.selection)
        let focused = clean(context.focusedText)
        let visible = clean(context.visibleText)

        // The selection says most clearly what you care about; then what you're writing; then
        // the window's title and the rest of what's visible.
        var parts: [String] = []
        if selection.count >= 12 { parts.append(selection) }
        if focused.count >= 12 { parts.append(focused) }
        let title = cleanTitle(context.windowTitle, app: context.appName)
        if !title.isEmpty { parts.append(title) }
        if !context.recipients.isEmpty { parts.append("To: " + context.recipients.joined(separator: ", ")) }
        parts.append(visible)
        var dense = ""
        for part in parts where !part.isEmpty {
            let room = denseBudget - dense.count
            guard room > 40 else { break }
            dense += (dense.isEmpty ? "" : "\n") + String(part.prefix(room))
        }

        let entitySource = [selection, focused, title, context.recipients.joined(separator: ", "), String(visible.prefix(6_000))]
            .joined(separator: "\n")
        let entities = Self.entities(in: entitySource) + context.recipients.flatMap(Self.names(inRecipient:))
        let identifiers = Self.identifiers(in: entitySource)
        var rare: [String] = []
        if let frequencies {
            rare = rareTerms(in: entitySource, frequencies: frequencies, excluding: Set(entities.map { $0.lowercased() }))
        }
        return Query(
            dense: dense,
            entities: Array(NSOrderedSet(array: entities).compactMap { $0 as? String }.prefix(12)),
            identifiers: Array(NSOrderedSet(array: identifiers).compactMap { $0 as? String }.prefix(8)),
            rareTerms: rare
        )
    }

    /// Drops what isn't the message: quoted replies, "On … wrote:" headers, signatures,
    /// and runs of whitespace.
    public static func clean(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        var lines: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "--" || trimmed == "-- " { break }
            if trimmed.hasPrefix(">") { continue }
            if trimmed.hasPrefix("On "), trimmed.hasSuffix("wrote:") { break }
            if trimmed.hasPrefix("-----Original Message") { break }
            if trimmed.hasPrefix("Sent from my") { continue }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Window titles often end with the app's name or a browser suffix.
    static func cleanTitle(_ title: String, app: String) -> String {
        var title = title
        for suffix in [" — \(app)", " - \(app)", " – \(app)", " - Google Chrome", " — Mozilla Firefox", " - Mozilla Firefox"] {
            if title.hasSuffix(suffix) { title = String(title.dropLast(suffix.count)) }
        }
        return title.trimmingCharacters(in: .whitespaces)
    }

    /// Names of people, organizations and places.
    public static func entities(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var found: [String] = []
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options) { tag, range in
            if let tag, [.personalName, .organizationName, .placeName].contains(tag) {
                let name = String(text[range]).trimmingCharacters(in: .punctuationCharacters)
                if name.count >= 3, !commonWords.contains(name.lowercased()) { found.append(name) }
            }
            return true
        }
        return found
    }

    /// "Dana Ruiz <dana@ruizbuilders.example>" → ["Dana Ruiz", "dana@ruizbuilders.example"].
    static func names(inRecipient recipient: String) -> [String] {
        var parts: [String] = []
        if let open = recipient.firstIndex(of: "<") {
            let name = recipient[..<open].trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "\"")))
            if name.count >= 3 { parts.append(name) }
        } else if !recipient.contains("@"), recipient.count >= 3 {
            parts.append(recipient)
        }
        return parts
    }

    /// Email addresses, phone numbers, street addresses, and order or invoice numbers.
    public static func identifiers(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var found: [String] = []
        let types: NSTextCheckingResult.CheckingType = [.phoneNumber, .address]
        if let detector = try? NSDataDetector(types: types.rawValue) {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, range: range) {
                if let r = Range(match.range, in: text) { found.append(String(text[r])) }
            }
        }
        let patterns = [
            "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}",
            // Invoice, order, case and permit numbers: letters and digits with at least 4 digits.
            "\\b(?:[A-Z]{1,5}[-#]?)?\\d{4,}(?:-\\d+)*\\b",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(match.range, in: text) {
                    let token = String(text[r])
                    // Years and long plain numbers are noise.
                    if let n = Int(token), (1900...2100).contains(n) || token.count > 12 { continue }
                    found.append(token)
                }
            }
        }
        return found
    }

    /// Words from the context that are rare in the index: present in it, in fewer than 1%
    /// of units. The rarest few.
    static func rareTerms(
        in text: String, frequencies: ([String]) -> (counts: [String: Int], total: Int), excluding: Set<String>
    ) -> [String] {
        // Nouns only: verbs and adjectives ("need", "call", "through") are rare in a small
        // index without saying anything about the topic.
        var words: [String: Int] = [:]
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitPunctuation, .omitWhitespace]) { tag, range in
            guard tag == .noun || tag == .otherWord else { return true }
            let word = text[range].lowercased()
            if word.count >= 4, !commonWords.contains(word), !excluding.contains(word), !word.allSatisfy(\.isNumber) {
                words[word, default: 0] += 1
            }
            return true
        }
        guard !words.isEmpty else { return [] }
        // FTS5 stores porter-stemmed terms; ask for the word as written and a crude stem.
        let candidates = Array(words.keys.prefix(300))
        let (counts, total) = frequencies(candidates + candidates.map(stem))
        guard total > 0 else { return [] }
        let limit = max(2, total / 100)
        return candidates
            .compactMap { word -> (String, Int)? in
                let df = counts[word] ?? counts[stem(word)] ?? 0
                return df > 0 && df <= limit ? (word, df) : nil
            }
            .sorted { $0.1 < $1.1 }
            .prefix(8)
            .map(\.0)
    }

    static func stem(_ word: String) -> String {
        for suffix in ["ing", "ed", "es", "s"] where word.count > suffix.count + 3 && word.hasSuffix(suffix) {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    static let commonWords: Set<String> = [
        "this", "that", "with", "from", "have", "will", "your", "about", "would", "there", "their", "what",
        "which", "when", "were", "they", "them", "then", "than", "been", "also", "just", "like", "more",
        "some", "into", "only", "other", "could", "should", "here", "thanks", "thank", "hello", "best",
        "regards", "please", "sent", "reply", "forward", "subject", "today", "tomorrow", "yesterday",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january",
        "february", "march", "april", "june", "july", "august", "september", "october", "november",
        "december", "file", "edit", "view", "window", "help", "inbox", "mail", "message", "untitled",
        "google", "chrome", "safari", "gmail", "search", "home", "settings", "share", "new", "open",
    ]
}
