import Foundation

/// An explicit question, separate from screen context and the suggestion journal.
public struct SearchRequest: Sendable, Codable {
    public var text: String
    public var limit: Int
    public var token: SearchToken?
    /// Only names mentioned in this query and their resolved conversations. Supplied by
    /// the app's existing, permission-gated Contacts directory; transient and never logged.
    public var contacts: [SearchContact]? = nil

    public init(text: String, limit: Int = 20, token: SearchToken? = nil) {
        self.text = text
        self.limit = limit
        self.token = token
    }
}

public struct SearchContact: Sendable, Codable, Equatable {
    public var name: String
    public var chatIDs: [Int64]
    public init(name: String, chatIDs: [Int64]) { self.name = name; self.chatIDs = chatIDs }
}

/// Searches the same text and image embeddings as recall, with exact-name matching too.
/// Uses literal terms, bounded freshness and distinct discussions, independently of the
/// ambient interruption policy. Queries and results are never journaled; exclusions apply.
public struct Search: Sendable {
    public let recall: Recall
    public let messages: MessagesReader?

    public init(recall: Recall, messages: MessagesReader? = nil) { self.recall = recall; self.messages = messages }

    public func run(_ request: SearchRequest, sources: SourceSettings, now: Date = Date()) async throws -> RecallResponse {
        try Task.checkCancellation()
        let prepared = ContinuousClock.now
        let text = String(request.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000))
        guard !text.isEmpty else {
            return RecallResponse(suggestions: [], query: .init(entities: [], rareTerms: [], denseCharacters: 0), milliseconds: 0)
        }
        let query = try SearchQuery(text, store: recall.store)
        let hidden = Set(try recall.store.neverShown())
        let limit = min(max(request.limit, 1), 20)
        let contactChats = Set((request.contacts ?? []).flatMap(\.chatIDs))
        let sourceExcluded = FileScanner(settings: sources).isExcluded((messages ?? MessagesReader()).database.url.path)
        func allowed(_ item: Item) -> Bool {
            !hidden.contains(item.id) && !sources.excludedKinds.contains(item.kind)
                && (sources.notes || item.source != .notes) && (sources.messages || item.source != .messages)
                && (!sourceExcluded || item.source != .messages)
                && !FileScanner(settings: sources).isExcluded(item.fileURL?.path ?? item.path)
        }
        SearchTrace.current?.record(.preparation, since: prepared)
        try Task.checkCancellation()
        // Named people are resolved as metadata, not added to every stored embedding. The
        // model searches the subject; matching contacts independently support the ranking.
        var subject = text
        for contact in request.contacts ?? [] {
            subject = subject.replacingOccurrences(of: "\\b" + NSRegularExpression.escapedPattern(for: contact.name) + "\\b",
                                                   with: " ", options: [.regularExpression, .caseInsensitive])
        }
        if SearchQuery.tokens(subject).allSatisfy(SearchQuery.filler.contains) { subject = text }
        let vector = try await recall.embedder.embed(queries: [subject])[0]
        try Task.checkCancellation()
        let vectorStarted = ContinuousClock.now
        // Passage-level deduplication needs a wider retrieval pool than the visible list.
        // Refill below if repeated windows still leave too few distinct candidates.
        var budget = 2_000
        var textHits = recall.vectors.search(vector, kind: .text, limit: budget)
        let imageHits = recall.vectors.search(vector, kind: .image, limit: 120)
        SearchTrace.current?.record(.vector, since: vectorStarted)
        let fullTextStarted = ContinuousClock.now
        var lexical = try recall.store.fullText(query.fullText, limit: 1_000)
        SearchTrace.current?.record(.fullText, since: fullTextStarted)
        let rankStarted = ContinuousClock.now
        defer { SearchTrace.current?.record(.ranking, since: rankStarted) }

        struct Candidate {
            var item: Item
            var unit: Unit
            var cosine: Double
            var fusion: Double
            var coverage: Double
            var score: Double
            var messageIDs = Set<Int64>()
        }
        var coverageCache: [Int64: (title: String, text: String, value: Double)] = [:]
        func scored(_ textHits: [VectorIndex.Hit]) throws -> [Candidate] {
            var fused: [Int64: Double] = [:]
            var cosines: [Int64: Double] = [:]
            for (hits, weight) in [(textHits, 1.0), (imageHits, 0.9)] {
                for (rank, hit) in hits.enumerated() {
                    fused[hit.id, default: 0] += weight / (60 + Double(rank + 1))
                    cosines[hit.id] = Double(hit.score)
                }
            }
            for (rank, hit) in lexical.enumerated() { fused[hit.unitID, default: 0] += 0.8 / (60 + Double(rank + 1)) }
            let units = try recall.store.units(ids: Array(fused.keys))
            let items = try recall.store.items(ids: Array(Set(units.values.map(\.itemID))))
            let missing = try recall.store.vectors(unitIDs: Array(fused.keys.filter { cosines[$0] == nil }))
            for (id, stored) in missing { cosines[id] = Double(zip(stored, vector).reduce(Float(0)) { $0 + $1.0 * $1.1 }) }
            var best: [Int64: Candidate] = [:]
            for (id, fusion) in fused {
                try Task.checkCancellation()
                guard let unit = units[id], let item = items[unit.itemID], allowed(item) else { continue }
                let coverage: Double
                if let cached = coverageCache[id], cached.title == item.title, cached.text == unit.text {
                    coverage = cached.value
                } else {
                    coverage = query.coverage(in: item.title + "\n" + unit.text)
                    coverageCache[id] = (item.title, unit.text, coverage)
                }
                let cosine = cosines[id] ?? 0
                let contact = item.message.map { contactChats.contains($0.chatID) } == true
                // Personal search should retain strong old matches while giving recent
                // correspondence a bounded freshness signal. Ambient ranking is separate.
                let age = max(0, now.timeIntervalSince(item.modified) / 86_400)
                let freshness = exp(-log(2) * age / 90)
                let score = 0.55 * cosine + 0.20 * coverage + 0.05 * min(1, fusion * 34)
                    + 0.20 * freshness + (contact ? 0.15 : 0)
                let candidate = Candidate(item: item, unit: unit, cosine: cosine, fusion: fusion, coverage: coverage, score: score)
                if best[item.id].map({ $0.score < score }) ?? true { best[item.id] = candidate }
            }
            return best.values.sorted { $0.score == $1.score ? $0.item.id < $1.item.id : $0.score > $1.score }
        }
        func distinct(_ candidates: [Candidate], maximum: Int) -> [Candidate] {
            var result: [Candidate] = []
            var byChat: [Int64: [Int]] = [:]
            for candidate in candidates {
                if candidate.item.kind == .message, let chat = candidate.item.message?.chatID {
                    let duplicate = (byChat[chat] ?? []).contains { index in
                        let previous = result[index]
                        if !candidate.messageIDs.isEmpty, !previous.messageIDs.isEmpty {
                            let common = candidate.messageIDs.intersection(previous.messageIDs).count
                            return Double(common) / Double(max(1, min(candidate.messageIDs.count, previous.messageIDs.count))) >= 0.65
                        }
                        return abs(candidate.item.created.timeIntervalSince(previous.item.created)) < 86_400
                            && MessagePassage.overlaps(candidate.unit.text, previous.unit.text)
                    }
                    if duplicate { continue }
                    byChat[chat, default: []].append(result.count)
                }
                result.append(candidate)
                if result.count == maximum { break }
            }
            return result
        }
        let initial = try scored(textHits)
        var chatIDs = Array(contactChats.sorted().prefix(24))
        for entry in initial where entry.item.kind == .message {
            if let id = entry.item.message?.chatID, !chatIDs.contains(id) { chatIDs.append(id) }
            if chatIDs.count >= 24 { break }
        }
        let recent = sources.messages ? try recall.store.recentMessageHits(query.fullText, chatIDs: chatIDs) : []
        let lexicalSet = Set(lexical.map(\.unitID))
        lexical += recent.filter { !lexicalSet.contains($0.unitID) }
        var ranked = try scored(textHits)
        var candidates = distinct(ranked, maximum: 400)
        while candidates.count < 80, textHits.count == budget, budget < 4_000 {
            try Task.checkCancellation()
            budget = min(4_000, budget * 2)
            textHits = recall.vectors.search(vector, kind: .text, limit: budget)
            ranked = try scored(textHits)
            candidates = distinct(ranked, maximum: 400)
        }
        try Task.checkCancellation()
        // Preserve follow-up passages even when large keyword-rich documents dominate
        // the preliminary ranking, before their broader discussion has been considered.
        let recentIDs = Set(recent.map(\.unitID))
        let followups = distinct(ranked.filter { recentIDs.contains($0.unit.id) }, maximum: 80)
        let existingIDs = Set(candidates.map { $0.item.id })
        candidates += followups.filter { !existingIDs.contains($0.item.id) }
        let anchorPool = followups + candidates.filter { !recentIDs.contains($0.unit.id) }
        let anchors = Array(anchorPool.filter { $0.item.kind == .message }.prefix(160))
        let blocked = hidden.union(try recall.store.itemIDs(under: sources.excludes))
        let blockedRows = Set(try recall.store.items(ids: Array(blocked)).values
            .filter { $0.kind == .message }.compactMap { $0.message?.rowID })
        let canReadMessages = sources.messages && messages.map { !FileScanner(settings: sources).isExcluded($0.database.url.path) } == true
        let expanded: [Int64: MessagePassage]? = canReadMessages
            ? try? messages?.searchPassages(for: anchors.map(\.item), excluding: blockedRows, excludes: sources.excludes) : nil
        var stale = Set<Int64>()
        for index in candidates.indices where candidates[index].item.kind == .message {
            try Task.checkCancellation()
            if let expanded, anchors.contains(where: { $0.item.id == candidates[index].item.id }),
               expanded[candidates[index].item.id] == nil {
                stale.insert(candidates[index].item.id)
                continue
            }
            var passage = expanded?[candidates[index].item.id]
            if passage == nil, anchors.contains(where: { $0.item.id == candidates[index].item.id }) {
                // Existing indexes and clients without access to chat.db can still expand
                // into related indexed passages. Exclusions apply to every added passage.
                let neighbours = try recall.store.searchMessageNeighbours(of: candidates[index].item).filter { allowed($0.0) }
                let base = candidates[index].unit.text
                let identifiers = MessagePassage.indexedIdentifiers(base)
                var lines = base.split(separator: "\n").map(String.init)
                var seen = Set(lines)
                var ids = Set(candidates[index].item.message.map { [$0.rowID] } ?? [])
                for (item, unit) in neighbours {
                    let shared = identifiers.intersection(MessagePassage.indexedIdentifiers(unit.text))
                    guard !shared.isEmpty || MessagePassage.overlaps(base, unit.text) else { continue }
                    for line in unit.text.split(separator: "\n").map(String.init) where !seen.contains(line) {
                        guard lines.joined(separator: "\n").count + line.count < 6_000 else { break }
                        lines.append(line); seen.insert(line)
                    }
                    if let id = item.message?.rowID { ids.insert(id) }
                }
                passage = MessagePassage(text: lines.joined(separator: "\n"), messageIDs: ids)
            }
            if let passage {
                let coverage = query.coverage(in: candidates[index].item.title + "\n" + passage.text)
                // Wider context helps resolve the subject without rewarding verbosity.
                candidates[index].score += 0.20 * max(0, coverage - candidates[index].coverage)
                candidates[index].coverage = max(coverage, candidates[index].coverage)
                candidates[index].unit.text = passage.text
                candidates[index].messageIDs = passage.messageIDs
            }
        }
        candidates.removeAll { stale.contains($0.item.id) }
        candidates.sort { $0.score == $1.score ? $0.item.id < $1.item.id : $0.score > $1.score }
        let chosen = distinct(candidates, maximum: limit)
        let stats = Stats(textHits.prefix(200).map { Double($0.score) })
        let lexicalIDs = Set(lexical.map(\.unitID))
        let question = Question(ContextSnapshot(selection: text, origin: .text))
        let suggestions = chosen.map { entry in
            let features = Features(cosine: entry.cosine, zScore: stats.z(entry.cosine),
                agreement: lexicalIDs.contains(entry.unit.id), entityHit: entry.item.message.map { contactChats.contains($0.chatID) } == true,
                daysSinceTouched: max(0, now.timeIntervalSince(entry.item.lastTouched) / 86_400),
                fused: entry.fusion, forgotten: 1, novelty: 1)
            let reasonQuery = Query(dense: text, entities: [], identifiers: [], rareTerms: query.terms)
            return Suggestion(item: entry.item, unit: entry.unit,
                reason: Recall.reason(entry.item, unit: entry.unit, matched: nil, query: reasonQuery, now: now),
                snippet: Recall.snippet(entry.unit.text, around: query.terms.first { entry.unit.text.localizedCaseInsensitiveContains($0) }),
                score: entry.score, confidence: Confidence.estimate(features), features: features,
                line: question.flatMap { MatchedLine.find(in: entry.unit.text, for: $0, terms: query.terms) })
        }
        return RecallResponse(suggestions: suggestions, query: query.summary,
                              milliseconds: SearchTrace.milliseconds(since: prepared))
    }
}
