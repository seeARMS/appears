import Foundation
import NaturalLanguage

/// What the context asks for, when it asks for a specific value: "What was the wifi password
/// again?" asks for a password (and mentions wifi); "When were the brakes last looked at?"
/// asks for a date. A question about something else ("What did Priya say about the venues?")
/// isn't one: there the whole passage is the answer, and the snippet shows it.
public struct Question: Sendable, Equatable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case date, phone, address, email, money
        /// Any code or number: a confirmation number, a PIN, "trout-meadow-88".
        case number
    }

    /// The kinds of value that would answer it.
    public var kinds: Set<Kind>
    /// The question's own words, lowercased, in the order asked, without question words and
    /// filler. A line labelled with one of them ("Password: …") answers it.
    public var words: [String]

    public init(kinds: Set<Kind>, words: [String]) {
        self.kinds = kinds
        self.words = words
    }

    /// The question in what you've selected or are writing (or in the window's title), else
    /// the last ones in the rest of the window. Nil when nothing there asks for a value.
    public init?(_ context: ContextSnapshot) {
        let written = [context.selection, context.focusedText].map(QueryBuilder.clean).joined(separator: "\n")
        // Titles and pages are full of headings ("Where to eat in Lisbon", "When to plant
        // tomatoes"): there, only a question mark makes a question.
        let title = QueryBuilder.cleanTitle(context.windowTitle, app: context.appName)
        var asked = Self.questions(in: written) + Self.questions(in: title, marked: true)
        if asked.isEmpty {
            asked = Array(Self.questions(in: QueryBuilder.clean(String(context.visibleText.suffix(3_000))), marked: true).suffix(2))
        }
        guard !asked.isEmpty else { return nil }
        kinds = asked.reduce(into: []) { $0.formUnion($1.kinds) }
        words = NSOrderedSet(array: asked.flatMap(\.words)).compactMap { $0 as? String }
    }

    /// Each sentence in `text` that asks for a value (and ends with a question mark, if `marked`).
    static func questions(in text: String, marked: Bool = false) -> [Question] {
        var found: [Question] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            tokenizer.string = line
            tokenizer.enumerateTokens(in: line.startIndex..<line.endIndex) { range, _ in
                let sentence = String(line[range])
                if !marked || sentence.contains("?"), let question = Question(sentence: sentence) { found.append(question) }
                return true
            }
        }
        return found
    }

    /// One sentence, if it asks for a value: a question starting with when, where, how much,
    /// "what's the …", or one naming a kind of value ("what was the wifi password"); or a
    /// request for one ("do you have the gate code", "I need the account number").
    init?(sentence: String) {
        var text = sentence.lowercased().replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
        // "Re: …", "So, when…", "Hey, what's…"
        text = text.replacingOccurrences(of: #"^(?:(?:re|fwd?)\s*:\s*)+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^(?:(?:so|and|also|but|hey|hi|ok|okay|oh|btw|sorry|quick question)\b[,!:]?\s*)+"#, with: "", options: .regularExpression)
        let first = String(text.prefix { $0.isLetter || $0 == "'" })
        var kinds: Set<Kind> = []
        if first.hasPrefix("when") || Self.contains(text, #"\b(?:what|which) (?:date|day|time|year|month)\b|\bhow long ago\b|\bsince when\b|\b(?:remember|know|recall) when\b|\bdates?\b"#) {
            kinds.insert(.date)
        }
        if first.hasPrefix("where") || Self.contains(text, #"(?<!email |e-mail |ip |web |mac )\baddress\b"#) { kinds.insert(.address) }
        if Self.contains(text, #"\b(?:phone|cell|mobile|telephone)\b"#) { kinds.insert(.phone) }
        if Self.contains(text, #"\be-?mail\b"#) { kinds.insert(.email) }
        if Self.contains(text, #"\bhow much\b|\b(?:price|cost|costs|total|amount|fee|charge|balance|rent|deposit|paid|owe)\b"#) { kinds.insert(.money) }
        if Self.contains(text, #"\bhow many\b|\b(?:number|no\.|id|code|pin|confirmation|reference|tracking|serial|account|policy|member|mileage|vin|password|passcode)\b|#"#) {
            kinds.insert(.number)
        }
        let asks: Bool
        switch first {
        case "when", "when's", "where", "where's":
            asks = true
        case "how", "how's":
            asks = Self.contains(text, #"^how (?:much|many|long ago|old)\b"#)
        case "what", "what's", "whats", "which", "who", "who's", "whose":
            asks = !kinds.isEmpty || Self.contains(text, Self.valueNouns)
                || Self.contains(text, #"^(?:what|which|who)(?:'s|s| is| was| are| were)\s+(?:the|my|our|your|their|his|her|its)\b"#)
        default:
            // "Do you have the wifi password?", "I need the account number", "remind me of the
            // address". A yes/no question that names a value in passing ("did you get my
            // email?") isn't asking for one.
            asks = Self.contains(text, #"\b(?:need|send|forgot|forget|remind|share|text|give|have|know|remember|lost|find)\b(?:\s+\S+){0,2}?\s+(?:the|your|my|our|his|her|their)\s+(?:\S+\s+){0,2}?"# + Self.valueNouns)
        }
        guard asks else { return nil }
        self.kinds = kinds
        words = text
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-#")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-#")) }
            .filter { $0.count >= 3 && !$0.allSatisfy(\.isNumber) && !Self.filler.contains($0) && !QueryBuilder.commonWords.contains($0) }
    }

    /// Nouns that name a value you'd look up.
    static let valueNouns = #"\b(?:password|passcode|pin|code|wi-?fi|network|ssid|number|phone|address|e-?mail|dates?|price|cost|total|amount|account|routing|policy|confirmation|reference|booking|reservation|tracking|serial|license|plate|vin|username|login|combination|extension|mileage|balance)\b"#

    /// Question words, pronouns and helpers: they say nothing about which line answers.
    static let filler: Set<String> = [
        "what", "whats", "when", "whens", "where", "wheres", "which", "who", "whos", "whose", "how", "the", "and", "are",
        "was", "were", "did", "does", "has", "had", "can", "you", "our", "his", "her", "its", "they", "any", "for", "get",
        "got", "again", "last", "still", "know", "remember", "recall", "tell", "give", "send", "need", "much", "many", "long", "ago", "ever", "exactly", "actually", "think", "sure",
        "anyone", "someone", "something", "remind", "forgot", "forget", "find", "there", "share", "text", "lost",
    ]

    static func contains(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

/// The line in a result that answers the question: "Password: trout-meadow-88" from a photo of
/// a cabin's welcome card, "Service date: August 14, 2023" from a garage's invoice. Always the
/// item's own text, quoted, never generated, so it can't invent anything.
public struct MatchedLine: Sendable, Codable, Hashable {
    public struct Segment: Sendable, Codable, Hashable {
        public var text: String
        /// The part that answers: the value after a label, the date, the amount.
        public var emphasized: Bool

        public init(_ text: String, emphasized: Bool = false) {
            self.text = text
            self.emphasized = emphasized
        }
    }

    /// One line, or two when a value needs its neighbour ("WiFi: …" above "Password: …"),
    /// separated by a newline segment.
    public var segments: [Segment]
    /// A password or a door code: copied with the concealed pasteboard type, so clipboard
    /// managers leave it out of their history.
    public var concealed: Bool

    public init(segments: [Segment], concealed: Bool = false) {
        self.segments = segments
        self.concealed = concealed
    }

    /// The line as it appears in the item: what ⌥⌘C copies.
    public var text: String { segments.map(\.text).joined() }

    /// Longer lines are cut to about this many characters around the answer.
    static let displayLimit = 140

    /// The line of `text` that best answers `question`, or nil if none does. A line answers if
    /// it holds a value of the kind asked for (a date for "when") or is labelled with a word
    /// of the question ("Password: …" for "the wifi password"); the question's other words and
    /// `terms` (the context's names and rare words) break ties.
    public static func find(in text: String, for question: Question, terms: [String] = []) -> MatchedLine? {
        let lines = Self.lines(text)
        let detector = question.kinds.isDisjoint(with: [.date, .phone, .address]) ? nil : try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType([.date, .phoneNumber, .address]).rawValue
        )
        let terms = terms.map { $0.lowercased() }.filter { $0.count >= 3 }
        let candidates = lines.map { evaluate($0, question: question, terms: terms, detector: detector) }
        var best: Int?
        for (index, candidate) in candidates.enumerated() {
            guard let candidate, candidate.qualifies else { continue }
            if best == nil || candidate.score > candidates[best!]!.score { best = index }
        }
        guard let best, let primary = candidates[best] else { return nil }

        // A short "Label: value" line keeps its partner next to it: the network with its
        // password, the username with its PIN.
        var included = [best]
        if let label = primary.label, lines[best].count <= 60 {
            let partner = [best - 1, best + 1]
                .filter { lines.indices.contains($0) && lines[$0].count <= 60 }
                .compactMap { index -> (index: Int, rank: Int)? in
                    guard let candidate = candidates[index], let other = candidate.label else { return nil }
                    if candidate.labelMatch != nil || candidate.overlap > 0 { return (index, 0) }
                    if partnerLabels.contains(where: { $0.contains(key(label.last ?? "")) && $0.contains(key(other.last ?? "")) && label != other }) { return (index, 1) }
                    return nil
                }
                .min { $0.rank != $1.rank ? $0.rank < $1.rank : $0.index < $1.index }
            if let partner { included.append(partner.index) }
        }

        var segments: [Segment] = []
        var concealed = false
        for index in included.sorted() {
            guard let candidate = candidates[index] else { continue }
            if !segments.isEmpty { segments.append(Segment("\n")) }
            segments += Self.segments(lines[index], emphasis: candidate.emphasis)
            if let label = candidate.label, Question.contains(label.joined(separator: " "), secretLabel) { concealed = true }
        }
        return MatchedLine(segments: segments, concealed: concealed)
    }

    // MARK: - Lines

    /// The text's lines, as quoted: whitespace collapsed, Markdown bullets and emphasis marks
    /// dropped, paragraphs cut into sentences, and a label on a line of its own ("Password:")
    /// joined to the value on the next.
    static func lines(_ text: String) -> [String] {
        var lines: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.replacingOccurrences(of: #"^\s*(?:[-*•+]|#{1,6}|\d{1,2}[.)])\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\*\*|__|`"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.count <= 200 {
                lines.append(line)
                continue
            }
            tokenizer.string = line
            tokenizer.enumerateTokens(in: line.startIndex..<line.endIndex) { range, _ in
                let sentence = line[range].trimmingCharacters(in: .whitespaces)
                if !sentence.isEmpty { lines.append(sentence) }
                return true
            }
        }
        var joined: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if index + 1 < lines.count, line.count <= 32, line.hasSuffix(":"), !lines[index + 1].contains(":") {
                joined.append(line + " " + lines[index + 1])
                index += 2
            } else {
                joined.append(line)
                index += 1
            }
        }
        return joined
    }

    // MARK: - Scoring one line

    struct Candidate {
        var score: Double
        var qualifies: Bool
        var emphasis: [Range<String.Index>]
        /// The words of the line's leading label, if it starts with one ("Hot tub: …").
        var label: [String]?
        /// The position in the question of the word its label matched.
        var labelMatch: Int?
        var overlap: Int
    }

    static func evaluate(_ line: String, question: Question, terms: [String], detector: NSDataDetector?) -> Candidate? {
        var score = 0.0
        var qualifies = false

        // A value of the kind asked for. Dates, phone numbers, addresses, emails and amounts
        // are specific; "a number" is weak evidence on its own.
        var specific: [Range<String.Index>] = []
        var numbers: [Range<String.Index>] = []
        for kind in question.kinds {
            let found = ranges(of: kind, in: line, detector: detector)
            if kind == .number { numbers += found } else { specific += found }
        }
        if !specific.isEmpty {
            score += 3
            qualifies = true
        } else if !numbers.isEmpty {
            score += 1.5
        }

        // A label named in the question: "Password: …" for "what was the wifi password".
        let pairs = labelPairs(in: line)
        var labelMatch: (index: Int, value: Range<String.Index>)?
        for pair in pairs {
            let keys = Set(pair.label.map(key))
            if let index = question.words.indices.last(where: { keys.contains(key(question.words[$0])) }),
               index > labelMatch?.index ?? -1 {
                labelMatch = (index, pair.value)
            }
        }
        if let labelMatch {
            // Later words weigh a little more: "wifi password" asks for the password.
            score += 3 + 0.1 * Double(labelMatch.index)
            qualifies = true
        }

        // The question's other words, and the context's names and rare words.
        let lineKeys = Set(tokens(line).map(key))
        let overlap = Set(question.words.map(key)).intersection(lineKeys).count
        score += Double(overlap)
        let lower = line.lowercased()
        score += 0.5 * Double(terms.filter { lower.contains($0) }.count)
        if !numbers.isEmpty, overlap > 0 { qualifies = true }

        // What to emphasize: the labelled value (or the asked-for part of it), else the values.
        var emphasis: [Range<String.Index>]
        if let labelMatch {
            let inside = (specific.isEmpty ? numbers : specific).filter { labelMatch.value.contains($0.lowerBound) }
            emphasis = inside.isEmpty ? [labelMatch.value] : inside
        } else {
            emphasis = specific.isEmpty ? numbers : specific
        }
        let leading = pairs.first(where: \.leading)?.label
        // Neither an answer nor a "Label: value" line that could sit next to one.
        if !qualifies, leading == nil { return nil }
        return Candidate(score: score, qualifies: qualifies, emphasis: emphasis, label: leading,
                         labelMatch: labelMatch?.index, overlap: overlap)
    }

    /// "Label: value" pairs: the start of the line up to its first colon, then a capitalized
    /// word or two before a later colon ("Vehicle: 2019 Honda CR-V EX Mileage in: 42,118").
    static func labelPairs(in line: String) -> [(label: [String], value: Range<String.Index>, leading: Bool)] {
        let whole = NSRange(line.startIndex..., in: line)
        var labels: [(label: Range<String.Index>, colonEnd: String.Index, leading: Bool)] = []
        if let regex = try? NSRegularExpression(pattern: #"^([\p{L}\p{N}][\p{L}\p{N} #'’&/().-]{0,30}?)\s*:\s+(?=\S)"#),
           let match = regex.firstMatch(in: line, range: whole),
           let label = Range(match.range(at: 1), in: line), let all = Range(match.range, in: line),
           line[label].contains(where: \.isLetter) {
            labels.append((label, all.upperBound, true))
        }
        if let regex = try? NSRegularExpression(pattern: #"(?<=\s)(\p{Lu}[\p{L}\p{N}]*(?: \p{Ll}+){0,2})\s*:\s+(?=\S)"#) {
            for match in regex.matches(in: line, range: whole) {
                guard let label = Range(match.range(at: 1), in: line), let all = Range(match.range, in: line),
                      label.lowerBound >= (labels.last?.colonEnd ?? line.startIndex) else { continue }
                labels.append((label, all.upperBound, false))
            }
        }
        return labels.enumerated().map { offset, entry in
            let end = offset + 1 < labels.count ? labels[offset + 1].label.lowerBound : line.endIndex
            var value = entry.colonEnd..<end
            while value.upperBound > value.lowerBound, line[line.index(before: value.upperBound)].isWhitespace {
                value = value.lowerBound..<line.index(before: value.upperBound)
            }
            return (tokens(String(line[entry.label])), value, entry.leading)
        }
    }

    static func ranges(of kind: Question.Kind, in line: String, detector: NSDataDetector?) -> [Range<String.Index>] {
        let whole = NSRange(line.startIndex..., in: line)
        func matching(_ pattern: String) -> [Range<String.Index>] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: line, range: whole).compactMap { Range($0.range, in: line) }
        }
        func detected(_ type: NSTextCheckingResult.CheckingType) -> [Range<String.Index>] {
            (detector?.matches(in: line, range: whole) ?? []).filter { $0.resultType == type }.compactMap { Range($0.range, in: line) }
        }
        switch kind {
        case .date: return detected(.date)
        case .phone: return detected(.phoneNumber)
        case .address: return detected(.address)
        case .email: return matching(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)
        case .money: return matching(#"[$€£¥]\s?\d[\d,]*(?:\.\d{1,2})?|\b\d[\d,]*(?:\.\d{2})?\s?(?:USD|EUR|GBP|CAD|dollars)\b"#)
        case .number: return matching(#"(?<![\p{L}\p{N}])[\p{L}\p{N}#][\p{L}\p{N}#.,/-]*\p{N}[\p{L}\p{N}#.,/-]*(?<![.,/-])"#).filter { line[$0].count >= 3 }
        }
    }

    /// Labels that name a secret.
    static let secretLabel = #"\b(?:pass(?:word|code|phrase)?|pin|secret|combination|(?:door|gate|access|alarm|lock|security|garage|entry|unlock|wifi|wi-fi) (?:code|key))\b"#

    /// Labels whose values belong together.
    static let partnerLabels: [Set<String>] = [
        ["wifi", "network", "ssid", "wireless", "password", "pass", "passcode", "key"],
        ["username", "user", "login", "email", "account", "password", "pin", "passcode"],
        ["account", "routing", "iban", "swift", "bic", "sort"],
    ].map { Set($0.map(key)) }

    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
            .filter { !$0.isEmpty }
    }

    /// Compares words loosely: "brakes" and "brake", "Wi-Fi" and "wifi".
    static func key(_ word: String) -> String {
        let word = word.lowercased().replacingOccurrences(of: "-", with: "")
        for suffix in ["ing", "ed", "es", "s"] where word.count > suffix.count + 3 && word.hasSuffix(suffix) {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    // MARK: - Segments

    /// The line, cut to `displayLimit` around its first emphasized part, as plain and
    /// emphasized runs.
    static func segments(_ line: String, emphasis: [Range<String.Index>]) -> [Segment] {
        let characters = Array(line)
        var spans = emphasis
            .map { (line.distance(from: line.startIndex, to: $0.lowerBound), line.distance(from: line.startIndex, to: $0.upperBound)) }
            .sorted { $0.0 < $1.0 }
        // Merge overlaps.
        var merged: [(Int, Int)] = []
        for span in spans {
            if let last = merged.last, span.0 <= last.1 { merged[merged.count - 1].1 = max(last.1, span.1) } else { merged.append(span) }
        }
        spans = merged
        var start = 0, end = characters.count
        if characters.count > displayLimit {
            start = max(0, (spans.first?.0 ?? 0) - 40)
            end = min(characters.count, start + displayLimit)
            start = max(0, end - displayLimit)
        }
        var segments: [Segment] = []
        func append(_ from: Int, _ to: Int, emphasized: Bool) {
            guard to > from else { return }
            let text = String(characters[from..<to])
            if let last = segments.last, last.emphasized == emphasized {
                segments[segments.count - 1].text += text
            } else {
                segments.append(Segment(text, emphasized: emphasized))
            }
        }
        if start > 0 { segments.append(Segment("…")) }
        var cursor = start
        for span in spans {
            let from = max(span.0, start), to = min(span.1, end)
            guard to > from else { continue }
            append(cursor, from, emphasized: false)
            append(from, to, emphasized: true)
            cursor = to
        }
        append(cursor, end, emphasized: false)
        if end < characters.count { segments.append(Segment("…")) }
        return segments
    }
}
