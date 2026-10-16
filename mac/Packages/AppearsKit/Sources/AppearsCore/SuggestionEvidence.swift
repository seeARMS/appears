import Foundation
import NaturalLanguage

/// Presentation evidence from the retrieved source, never a generated explanation.
/// Does not change ranking or confidence, or retain the context that found the item.
public struct SuggestionEvidence: Sendable {
    public let segments: [MatchedLine.Segment]
    public let isQuotation: Bool
    public let metadata: String

    public init(_ suggestion: Suggestion, terms: [String] = []) {
        let parts = suggestion.reason.components(separatedBy: " · ")
        let reason = parts.first ?? ""
        let specific = !reason.isEmpty && reason != "Related" && reason != "Looks related"
        var metadata = Array(parts.dropFirst())
        if suggestion.item.source == .notes { metadata.insert("Notes", at: 0) }
        if suggestion.item.source == .messages { metadata.insert("Messages", at: 0) }
        self.metadata = metadata.joined(separator: " · ")

        var matched = terms
        if reason.hasPrefix("Mentions ") { matched.insert(String(reason.dropFirst(9)), at: 0) }
        if reason.hasPrefix("Also about “"), reason.hasSuffix("”") {
            matched.insert(String(reason.dropFirst(12).dropLast()), at: 0)
        }
        let keys = Array(Set(matched.map(Self.clean).filter { $0.count >= 3 && $0.count <= 256 })).sorted()

        // An answer has its own selected-row treatment, including concealed clipboard handling.
        let source = suggestion.unit.text.isEmpty ? suggestion.snippet : suggestion.unit.text
        let sentences = Self.sentences(String(source.prefix(16_000)))
        var best: (text: String, hits: Int)?
        for text in sentences {
            let hits = keys.filter { !Self.ranges(of: $0, in: text).isEmpty }.count
            if best == nil || hits > best!.hits { best = (text, hits) }
        }

        let passage: String?
        if suggestion.line != nil {
            passage = nil
        } else if let best, best.hits > 0 {
            passage = Self.excerpt(best.text, terms: keys)
        } else if suggestion.unit.kind != .image, !specific {
            // A meaning-only match still has a retrieved passage the person can judge.
            passage = Self.sentences(suggestion.snippet.isEmpty ? source : suggestion.snippet).first.map { Self.excerpt($0, terms: []) }
        } else {
            // Image similarity alone supplies no defensible written reason. Keep its thumbnail.
            passage = nil
        }
        isQuotation = passage != nil
        segments = Self.segments(passage ?? (specific ? reason : ""), terms: keys)
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sentences(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).flatMap { paragraph -> [String] in
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = paragraph
            var result: [String] = []
            tokenizer.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { range, _ in
                let sentence = clean(String(paragraph[range]))
                let visible = sentence.filter { !$0.isWhitespace }
                // Discard OCR fragments and mostly numeric/layout noise.
                if sentence.count >= 18, sentence.split(separator: " ").count >= 3,
                   Double(visible.filter(\.isLetter).count) / Double(max(visible.count, 1)) >= 0.5 {
                    result.append(sentence)
                }
                return true
            }
            return result
        }
    }

    /// Whole words and phrases only: "permit" is not evidence in "permitted".
    private static func ranges(of term: String, in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex, let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if !(before?.isLetter ?? false), !(before?.isNumber ?? false),
               !(after?.isLetter ?? false), !(after?.isNumber ?? false) { ranges.append(range) }
            start = range.upperBound
        }
        return ranges
    }

    private static func excerpt(_ text: String, terms: [String]) -> String {
        guard text.count > 120 else { return text }
        let hit = terms.flatMap { ranges(of: $0, in: text) }.map(\.lowerBound).min() ?? text.startIndex
        var start = text.index(hit, offsetBy: -36, limitedBy: text.startIndex) ?? text.startIndex
        if start != text.startIndex {
            while start < hit, !text[text.index(before: start)].isWhitespace { start = text.index(after: start) }
        }
        var end = text.index(start, offsetBy: 120, limitedBy: text.endIndex) ?? text.endIndex
        if end != text.endIndex {
            while end > start, !text[end].isWhitespace { end = text.index(before: end) }
        }
        return (start == text.startIndex ? "" : "…") + clean(String(text[start..<end])) + (end == text.endIndex ? "" : "…")
    }

    private static func segments(_ text: String, terms: [String]) -> [MatchedLine.Segment] {
        guard !text.isEmpty else { return [] }
        var matches: [Range<String.Index>] = []
        for term in terms { matches.append(contentsOf: ranges(of: term, in: text)) }
        matches.sort { a, b in
            if a.lowerBound == b.lowerBound { return a.upperBound > b.upperBound }
            return a.lowerBound < b.lowerBound
        }
        var result: [MatchedLine.Segment] = []
        var start = text.startIndex
        for range in matches where range.lowerBound >= start {
            if start < range.lowerBound { result.append(.init(String(text[start..<range.lowerBound]))) }
            result.append(.init(String(text[range]), emphasized: true))
            start = range.upperBound
        }
        if start < text.endIndex { result.append(.init(String(text[start...]))) }
        return result
    }
}
