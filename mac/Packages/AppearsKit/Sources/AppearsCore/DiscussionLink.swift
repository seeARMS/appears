import Foundation

/// A shared reference is a discovery hint, not proof that two statements concern the
/// same subject. Require both stable conversation identity and semantic coherence.
enum DiscussionLink {
    private static let expression = try! NSRegularExpression(pattern: #"(?i)(?:[$€£]\s*)?\b(?:[a-z]+-?)?\d+(?:[.,]\d+)*(?:-[a-z0-9]+)*\b"#)

    static func references(_ text: String) -> Set<String> {
        return Set(expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let raw = String(text[range]).lowercased()
            let currency = raw.contains { "$€£".contains($0) }
            let token = raw.filter { !$0.isWhitespace && !"$€£,".contains($0) }
            // A year alone is too broad a connection. Currency amounts, short numbers,
            // decimals and alphanumeric references retain their complete value.
            if !currency, let year = Int(token), (1900...2100).contains(year) { return nil }
            return token
        })
    }

    static func connects(_ a: Unit, _ b: Unit, vectors: [Int64: [Float]]) -> Bool {
        guard !references(a.text).isDisjoint(with: references(b.text)),
              let left = vectors[a.id], let right = vectors[b.id], left.count == right.count else { return false }
        return VectorMath.dot(left, right) >= 0.8
    }
}
