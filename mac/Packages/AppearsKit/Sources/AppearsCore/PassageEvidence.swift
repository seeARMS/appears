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
    private let cache = Mutex<[EmbeddingDocument: [Float]]>([:])
    private let maximumDocuments = 128

    func vectors(for suggestions: [Suggestion]) -> [Int64: [Float]] {
        cache.withLock { values in
            Dictionary(uniqueKeysWithValues: suggestions.compactMap { result in
                guard let evidence = result.evidence,
                      let vector = values[EmbeddingDocument(title: "", text: evidence.text)] else { return nil }
                return (result.id, vector)
            })
        }
    }

    struct Passage {
        var item: Item
        var unit: Unit
        var text: String
        var sources: [PassageEvidence.Source]
        var document: EmbeddingDocument { EmbeddingDocument(title: "", text: text) }
    }

    func select(_ candidates: [Suggestion], query: [Float], embedder: any Embedder,
                store: IndexStore, messages: MessagesReader?, excluded: Set<Int64>,
                question: Question?, terms: [String]) async throws -> [Suggestion] {
        let forbidden = try store.neverShown().union(excluded)
        let anchors = candidates.filter { $0.item.source == .messages && $0.unit.kind == .text }
        // A caller must explicitly provide the source reader. Demo/eval/unit tests never
        // fall through to the person's real Messages database.
        let contexts = messages.map { reader in
            (try? reader.database.messagesWithThreads(
                rowIDs: Array(Set(anchors.compactMap { $0.item.message?.rowID })), before: 5, after: 2
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

        var choices: [[Passage]] = []
        var documents: [EmbeddingDocument] = []
        var admitted: Set<EmbeddingDocument> = []
        for candidate in candidates {
            try Task.checkCancellation()
            // Visual evidence and OCR keep their existing readability/overlap policy.
            guard candidate.unit.kind == .text, candidate.item.kind != .image || candidate.item.source == .messages else {
                choices.append([])
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
            var retained: [Passage] = []
            for passage in possible {
                let document = passage.document
                if !admitted.contains(document) {
                    guard documents.count < maximumDocuments else { continue }
                    admitted.insert(document)
                    documents.append(document)
                }
                retained.append(passage)
            }
            choices.append(retained)
        }

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
        for (candidate, passages) in zip(candidates, choices) {
            guard !forbidden.contains(candidate.id) else { continue }
            if candidate.unit.kind == .image || (candidate.item.kind == .image && candidate.item.source != .messages)
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
            let result = Suggestion(item: passage.item, unit: passage.unit, reason: candidate.reason,
                                    snippet: evidence.text, score: candidate.score * support,
                                    confidence: candidate.confidence * support, features: candidate.features,
                                    line: question.flatMap {
                                        MatchedLine.find(in: passage.item.source == .messages ? evidence.text : passage.unit.text, for: $0, terms: terms)
                                    },
                                    evidence: evidence, ambientEligible: candidate.ambientEligible)
            results.append(result)
        }

        // Revalidate source versions after inference: deletion, unsend or an edit while
        // the encoder worked cannot leave a stale quote in the response.
        if let messages, contexts != nil {
            let references = results.flatMap { $0.evidence?.sources.compactMap(\.message) ?? [] }
            let current = (try? messages.database.messagesWithThreads(rowIDs: Array(Set(references.map(\.rowID))), before: 0, after: 0)) ?? [:]
            results = results.filter { result in
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
            }
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
                // Read-only indexes without the source database can still collapse an
                // identical quoted passage from the same chat, without hiding distinct
                // discussions or treating a shared conversation name as identity.
                if let chat = result.item.message?.chatID, chat == previous.item.message?.chatID,
                   a.text == b.text { return true }
                return a.overlaps(b)
            }
            if !duplicate { unique.append(result) }
        }
        return unique
    }

    /// All offsets address the unmodified source string. Sentence boundaries are generic;
    /// no topic words, acronym lists, question types or generated answers are involved.
    static func passages(_ text: String, item: Item, unit: Unit, message: MessageReference?, modified: Date) -> [Passage] {
        var ranges: [Range<String.Index>] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byParagraphs, .substringNotRequired]) { _, paragraph, _, _ in
            let body = String(text[paragraph])
            tokenizer.string = body
            tokenizer.enumerateTokens(in: body.startIndex..<body.endIndex) { local, _ in
                let lower = text.index(paragraph.lowerBound, offsetBy: body.distance(from: body.startIndex, to: local.lowerBound))
                let upper = text.index(lower, offsetBy: body.distance(from: local.lowerBound, to: local.upperBound))
                var start = lower
                while start < upper {
                    var end = text.index(start, offsetBy: 480, limitedBy: upper) ?? upper
                    if end < upper, let space = text[start..<end].lastIndex(where: \.isWhitespace), space > start { end = space }
                    var trimmed = start..<end
                    while !trimmed.isEmpty, text[trimmed.lowerBound].isWhitespace { trimmed = text.index(after: trimmed.lowerBound)..<trimmed.upperBound }
                    while !trimmed.isEmpty, text[text.index(before: trimmed.upperBound)].isWhitespace { trimmed = trimmed.lowerBound..<text.index(before: trimmed.upperBound) }
                    if !trimmed.isEmpty { ranges.append(trimmed) }
                    start = end
                }
                return ranges.count < 24
            }
        }
        var combined = ranges
        for pair in zip(ranges, ranges.dropFirst()) {
            let range = pair.0.lowerBound..<pair.1.upperBound
            if text[range].count <= 480 { combined.append(range) }
        }
        return combined.map { range in
            let location = NSRange(range, in: text)
            return Passage(item: item, unit: unit, text: String(text[range]), sources: [
                PassageEvidence.Source(itemID: item.id, unitID: unit.id, message: message, modified: modified,
                                       utf16Location: location.location, utf16Length: location.length),
            ])
        }
    }
}
