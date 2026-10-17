import AppearsMessages
import Foundation
import NaturalLanguage
import Synchronization

/// The exact source ranges scored by the text encoder. Screen context never enters this
/// value. A row quotes `text`; it must not choose a different sentence using query words.
public struct PassageEvidence: Sendable, Codable, Hashable {
    public struct Source: Sendable, Codable, Hashable {
        public var itemID: Int64
        public var unitID: Int64
        public var message: MessageReference?
        public var modified: Date
        public var utf16Location: Int
        public var utf16Length: Int
    }

    public var text: String
    public var sources: [Source]
    public var cosine: Double

    /// Identities, rather than conversation names or similar wording, define duplicates.
    func overlaps(_ other: Self) -> Bool {
        sources.contains { a in
            other.sources.contains { b in
                let same = a.message.map { $0.guid == b.message?.guid && $0.chatID == b.message?.chatID }
                    ?? (b.message == nil && a.unitID == b.unitID)
                guard same else { return false }
                let overlap = max(0, min(a.utf16Location + a.utf16Length, b.utf16Location + b.utf16Length)
                                  - max(a.utf16Location, b.utf16Location))
                return overlap * 2 >= min(a.utf16Length, b.utf16Length)
            }
        }
    }
}

/// Retrieve broad windows first, then score short, verbatim passages inside them with
/// the same encoder. Existing index vectors remain valid. This cache holds source text
/// and document vectors only, in memory, with a fixed bound; never queries or screens.
final class PassageSelector: Sendable {
    static let maximumCandidates = 48
    private let cache = Mutex<[EmbeddingDocument: [Float]]>([:])
    // Reserve beginning, end and middle for every coarse candidate before adding
    // finer subdivisions. Keep this bound tied to Recall's candidate limit.
    private let maximumDocuments = PassageSelector.maximumCandidates * 3

    func vectors(for suggestions: [Suggestion]) -> [Int64: [Float]] {
        cache.withLock { values in
            Dictionary(uniqueKeysWithValues: suggestions.compactMap { result in
                guard let evidence = result.evidence,
                      let vector = values[EmbeddingDocument(title: result.item.title, text: evidence.text)] else { return nil }
                return (result.id, vector)
            })
        }
    }

    struct Passage {
        var item: Item
        var unit: Unit
        var text: String
        var sources: [PassageEvidence.Source]
        var document: EmbeddingDocument { EmbeddingDocument(title: item.title, text: text) }
    }

    func select(_ candidates: [Suggestion], query: [Float], embedder: any Embedder,
                store: IndexStore, messages: MessagesReader?, excluded: Set<Int64>,
                question: Question?, terms: [String]) async throws -> [Suggestion] {
        let forbidden = try store.neverShown().union(excluded)
        func usesImageEvidence(_ result: Suggestion) -> Bool {
            // Messages photos have their own OCR at .whole; only .chunk(0) is the
            // inherited conversation context appended by MessagesReader.extraction.
            result.item.kind == .image && !(result.item.source == .messages
                && result.unit.kind == .text && result.unit.locator == .chunk(0))
        }
        let anchors = candidates.filter { $0.item.source == .messages && $0.unit.kind == .text && !usesImageEvidence($0) }
        // A caller must explicitly provide the source reader. Demo/eval/unit tests never
        // fall through to the person's real Messages database.
        let contexts = messages.map { reader in
            (try? reader.database.messagesWithThreads(
                rowIDs: Array(Set(candidates.filter { $0.item.source == .messages }.compactMap { $0.item.message?.rowID })), before: 5, after: 2
            )) ?? [:]
        }
        var live: [Int64: [Passage]] = [:]
        if let contexts {
            for anchor in anchors {
                guard let reference = anchor.item.message, let context = contexts[reference.rowID],
                      context.message.guid == reference.guid, context.message.chatID == reference.chatID,
                      context.message.isSearchable else { continue }
                var passages: [Passage] = []
                var messagePassages: [[Passage]] = []
                for message in context.thread where message.isSearchable && message.chatID == reference.chatID
                    && abs(message.date.timeIntervalSince(context.message.date)) <= 30 * 60 {
                    guard let text = message.text, !text.isEmpty,
                          let item = try store.item(path: MessagesReader.path(message.rowID)),
                          item.message?.guid == message.guid, item.message?.chatID == message.chatID,
                          !forbidden.contains(item.id),
                          let unit = try store.units(itemID: item.id).first(where: { $0.unit.kind == .text })?.unit else { continue }
                    let spans = Self.passages(text, item: item, unit: unit, message: item.message,
                                              modified: max(message.date, message.editedAt ?? .distantPast))
                    passages += spans
                    messagePassages.append(spans)
                }
                // A short reply can need the preceding question. Both source ranges are
                // returned, so the quote and its navigation remain attributable.
                for pair in zip(messagePassages, messagePassages.dropFirst()) {
                    guard let first = pair.0.last, let second = pair.1.first,
                          first.text.count + second.text.count <= 480,
                          min(first.text.count, second.text.count) < 100 else { continue }
                    passages.append(Passage(item: second.item, unit: second.unit, text: first.text + "\n" + second.text,
                                            sources: first.sources + second.sources))
                }
                live[anchor.id] = passages
            }
        }

        var possibleChoices: [[Passage]] = []
        var documents: [EmbeddingDocument] = []
        var admitted: Set<EmbeddingDocument> = []
        // Preserve the existing structured value contract (dates, amounts, codes):
        // constrain candidate passages before semantic scoring, rather than extract
        // an unrelated value from the whole unit after choosing the displayed quote.
        func answersValue(_ passage: Passage) -> Bool {
            guard let question else { return false }
            return MatchedLine.find(in: passage.text, for: question, terms: terms) != nil
        }
        for candidate in candidates {
            try Task.checkCancellation()
            // Visual evidence and OCR keep their existing readability/overlap policy.
            guard candidate.unit.kind == .text, !usesImageEvidence(candidate) else {
                possibleChoices.append([])
                continue
            }
            let possible: [Passage]
            if contexts != nil, candidate.item.source == .messages {
                // An inaccessible/deleted/unsent source must never revive an old window.
                possible = live[candidate.id] ?? []
            } else {
                possible = Self.passages(candidate.unit.text, item: candidate.item, unit: candidate.unit,
                                         message: nil, modified: candidate.item.modified)
            }
            let answering = possible.filter(answersValue)
            possibleChoices.append(Self.spread(answering.isEmpty ? possible : answering))
        }
        // Share the fixed inference budget round-robin. A verbose early result must
        // not spend every slot before later candidates receive any source evidence.
        for offset in 0..<(possibleChoices.map(\.count).max() ?? 0) {
            for possible in possibleChoices where possible.indices.contains(offset) {
                let passage = possible[offset]
                let document = passage.document
                if !admitted.contains(document) {
                    guard documents.count < maximumDocuments else { continue }
                    admitted.insert(document)
                    documents.append(document)
                }
            }
        }
        let choices = possibleChoices.map { $0.filter { admitted.contains($0.document) } }

        var vectors = cache.withLock { values in
            Dictionary(uniqueKeysWithValues: documents.compactMap { document in values[document].map { (document, $0) } })
        }
        let missing = documents.filter { vectors[$0] == nil }
        for start in stride(from: 0, to: missing.count, by: 8) {
            try Task.checkCancellation()
            let batch = Array(missing[start..<min(start + 8, missing.count)])
            let embedded = try await embedder.embed(passages: batch)
            guard embedded.count == batch.count else { throw CancellationError() }
            for (document, vector) in zip(batch, embedded) { vectors[document] = vector }
        }
        try Task.checkCancellation()
        cache.withLock { values in
            if values.count + vectors.count > 512 { values.removeAll(keepingCapacity: true) }
            values.merge(vectors) { _, latest in latest }
        }

        var results: [Suggestion] = []
        var photoOrigins: [Int: Item] = [:]
        for (candidate, passages) in zip(candidates, choices) {
            guard !forbidden.contains(candidate.id) else { continue }
            if candidate.unit.kind == .image || usesImageEvidence(candidate)
                || candidate.unit.text.isEmpty {
                results.append(candidate)
                continue
            }
            let scored = passages.compactMap { passage -> (Passage, Double)? in
                guard let vector = vectors[passage.document] else { return nil }
                return (passage, Double(VectorMath.dot(query, vector)))
            }
            guard let best = scored.max(by: { a, b in
                a.1 == b.1 ? a.0.text.count > b.0.text.count : a.1 < b.1
            }) else { continue }
            let passage = best.0
            let evidence = PassageEvidence(text: passage.text, sources: passage.sources, cosine: best.1)
            // Fine-grained evidence can lower a broad match's relevance/confidence. It
            // cannot turn weak retrieval into a new confident ambient interruption.
            let support = min(1, max(0, best.1) / max(0.05, candidate.features.cosine))
            var unit = passage.unit
            // The indexed window can contain a now-hidden or unsent neighbour. Return
            // only the source text just validated above, including for inline previews.
            if passage.item.source == .messages, contexts != nil { unit.text = evidence.text }
            let result = Suggestion(item: passage.item, unit: unit, reason: candidate.reason,
                                    snippet: evidence.text, score: candidate.score * support,
                                    confidence: candidate.confidence * support, features: candidate.features,
                                    line: question.flatMap {
                                        MatchedLine.find(in: evidence.text, for: $0, terms: terms)
                                    },
                                    evidence: evidence, ambientEligible: candidate.ambientEligible)
            if candidate.item.source == .messages, candidate.item.kind == .image {
                photoOrigins[results.count] = candidate.item
            }
            results.append(result)
        }

        // Revalidate source versions after inference: deletion, unsend or an edit while
        // the encoder worked cannot leave a stale quote in the response.
        if let messages, contexts != nil {
            let references = results.compactMap { $0.item.source == .messages ? $0.item.message : nil }
                + results.flatMap { $0.evidence?.sources.compactMap(\.message) ?? [] }
                + photoOrigins.values.compactMap(\.message)
            let current = (try? messages.database.messagesWithThreads(rowIDs: Array(Set(references.map(\.rowID))), before: 0, after: 0)) ?? [:]
            let hiddenPhotos = try store.neverShown().union(excluded)
            func validPhoto(_ item: Item) -> Bool {
                guard !hiddenPhotos.contains(item.id), let reference = item.message, let message = current[reference.rowID]?.message,
                      message.isSearchable, message.guid == reference.guid, message.chatID == reference.chatID,
                      max(message.date, message.editedAt ?? .distantPast) == item.modified,
                      let path = reference.attachmentPath, messages.containsLocalPhoto(in: message, path: path) else { return false }
                return true
            }
            results = results.enumerated().filter { index, result in
                if result.item.source == .messages, result.item.kind == .image, !validPhoto(result.item) { return false }
                // Promoting inherited context changes the displayed item, but must not
                // erase the discovery photo's identity or bypass its invalidation.
                if let origin = photoOrigins[index], !validPhoto(origin) { return false }
                var verified: [String] = []
                let valid = (result.evidence?.sources ?? []).allSatisfy { source in
                    guard let reference = source.message else { return true }
                    guard let message = current[reference.rowID]?.message, message.isSearchable,
                          message.guid == reference.guid, message.chatID == reference.chatID,
                          max(message.date, message.editedAt ?? .distantPast) == source.modified,
                          let text = message.text,
                          source.utf16Location + source.utf16Length <= (text as NSString).length else { return false }
                    verified.append((text as NSString).substring(with: NSRange(location: source.utf16Location, length: source.utf16Length)))
                    return true
                }
                return valid && (verified.isEmpty || verified.joined(separator: "\n") == result.evidence?.text)
            }.map(\.element)
        }
        let hidden = try store.neverShown().union(excluded)
        let currentUnits = try store.units(ids: Array(Set(results.flatMap { result in
            result.evidence?.sources.filter { $0.message == nil }.map(\.unitID) ?? []
        })))
        let currentItems = try store.items(ids: Array(Set(results.flatMap { result in
            result.evidence?.sources.filter { $0.message == nil }.map(\.itemID) ?? []
        })))
        results = results.filter { result in
            guard !hidden.contains(result.id) else { return false }
            return (result.evidence?.sources ?? []).allSatisfy { source in
                guard !hidden.contains(source.itemID) else { return false }
                if source.message != nil { return true }
                guard let unit = currentUnits[source.unitID], unit.itemID == source.itemID,
                      currentItems[source.itemID]?.modified == source.modified,
                      NSMaxRange(NSRange(location: source.utf16Location, length: source.utf16Length)) <= (unit.text as NSString).length else { return false }
                return (unit.text as NSString).substring(with: NSRange(location: source.utf16Location, length: source.utf16Length)) == result.evidence?.text
            }
        }
        results.sort { $0.score > $1.score }
        var unique: [Suggestion] = []
        for result in results {
            let duplicate = unique.contains { previous in
                if previous.id == result.id { return true }
                guard let a = previous.evidence, let b = result.evidence else { return false }
                return a.overlaps(b)
            }
            if !duplicate { unique.append(result) }
        }
        return unique
    }

    /// All offsets address the unmodified source string. Sentence boundaries are generic;
    /// no topic words, acronym lists or generated answers are involved in segmentation.
    static func passages(_ text: String, item: Item, unit: Unit, message: MessageReference?, modified: Date) -> [Passage] {
        var ranges: [Range<String.Index>] = []
        let length = (text as NSString).length
        guard length > 0 else { return [] }
        var rangeCount = 0
        var previousSourceEnd = text.startIndex
        var previousUTF16End = 0
        var sampled = Array<(range: Range<String.Index>, distance: Int)?>(repeating: nil, count: 24)
        func admit(_ range: Range<String.Index>) {
            rangeCount += 1
            if ranges.count < 24 { ranges.append(range) }
            let location = previousUTF16End + text[previousSourceEnd..<range.lowerBound].utf16.count
            let size = text[range].utf16.count
            previousSourceEnd = range.upperBound
            previousUTF16End = location + size
            let middle = location + size / 2
            let slot = min(23, (middle * 23 + length / 2) / length)
            let distance = abs(middle * 23 - slot * length)
            if sampled[slot] == nil || distance < sampled[slot]!.distance {
                sampled[slot] = (range, distance)
            }
        }
        let tokenizer = NLTokenizer(unit: .sentence)
        // Walk the source once while retaining at most 24 ranges. If it contains more,
        // keep representatives across its full length, including both ends. Stopping
        // tokenization at range 24 would permanently make later answers unreachable.
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byParagraphs, .substringNotRequired]) { _, paragraph, _, _ in
            let body = String(text[paragraph])
            tokenizer.string = body
            var localCursor = body.startIndex
            var sourceCursor = paragraph.lowerBound
            tokenizer.enumerateTokens(in: body.startIndex..<body.endIndex) { local, _ in
                let lower = text.index(sourceCursor, offsetBy: body.distance(from: localCursor, to: local.lowerBound))
                let upper = text.index(lower, offsetBy: body.distance(from: local.lowerBound, to: local.upperBound))
                localCursor = local.upperBound
                sourceCursor = upper
                var start = lower
                while start < upper {
                    var end = text.index(start, offsetBy: 480, limitedBy: upper) ?? upper
                    if end < upper, let space = text[start..<end].lastIndex(where: \.isWhitespace), space > start { end = space }
                    var trimmed = start..<end
                    while !trimmed.isEmpty, text[trimmed.lowerBound].isWhitespace { trimmed = text.index(after: trimmed.lowerBound)..<trimmed.upperBound }
                    while !trimmed.isEmpty, text[text.index(before: trimmed.upperBound)].isWhitespace { trimmed = trimmed.lowerBound..<text.index(before: trimmed.upperBound) }
                    if !trimmed.isEmpty { admit(trimmed) }
                    start = end
                }
                return true
            }
        }
        if rangeCount > 24 { ranges = sampled.compactMap { $0?.range } }
        var combined = ranges
        for pair in zip(ranges, ranges.dropFirst()) {
            let range = pair.0.lowerBound..<pair.1.upperBound
            if text[range].count <= 480 { combined.append(range) }
        }
        return combined.sorted { a, b in
            a.lowerBound == b.lowerBound ? a.upperBound < b.upperBound : a.lowerBound < b.lowerBound
        }.map { range in
            let location = NSRange(range, in: text)
            return Passage(item: item, unit: unit, text: String(text[range]), sources: [
                PassageEvidence.Source(itemID: item.id, unitID: unit.id, message: message, modified: modified,
                                       utf16Location: location.location, utf16Length: location.length),
            ])
        }
    }

    /// Breadth-first subdivisions sample the beginning, end, middle, then quarters.
    /// A shared inference cap can reduce resolution, but cannot turn every candidate
    /// into a prefix-only search. Each quotation retains its exact source ranges.
    private static func spread(_ passages: [Passage]) -> [Passage] {
        guard passages.count > 2 else { return passages }
        var result = [passages[0], passages[passages.count - 1]]
        var intervals = [1..<(passages.count - 1)]
        var next = 0
        while next < intervals.count {
            let interval = intervals[next]
            next += 1
            guard !interval.isEmpty else { continue }
            let middle = interval.lowerBound + interval.count / 2
            result.append(passages[middle])
            intervals.append(interval.lowerBound..<middle)
            intervals.append((middle + 1)..<interval.upperBound)
        }
        return result
    }
}
