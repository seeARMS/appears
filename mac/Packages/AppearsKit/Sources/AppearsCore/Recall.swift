import Foundation
import Synchronization

public enum Trigger: String, Sendable, Codable {
    /// You asked: the hotkey or a click.
    case pull
    /// Appears looked on its own after you settled into a context.
    case ambient
}

public struct RecallRequest: Sendable, Codable {
    public var context: ContextSnapshot
    public var trigger: Trigger
    public var limit: Int
    /// Items already shown for this context, so they don't come back.
    public var exclude: [Int64]

    public init(context: ContextSnapshot, trigger: Trigger, limit: Int = 3, exclude: [Int64] = []) {
        self.context = context
        self.trigger = trigger
        self.limit = limit
        self.exclude = exclude
    }
}

/// The measurements behind one suggestion, logged in the journal (numbers only, never text).
public struct Features: Sendable, Codable, Hashable {
    /// Similarity of the matched unit (or its verified passage) to the query: how it was found.
    public var cosine: Double
    public var daysSinceTouched: Double
    /// The context asks your own memory for something ("what was the wifi password again?").
    public var recallIntent: Bool
    /// The decision model's probability that this is the item; nil when no decision ran.
    public var probability: Double?
    /// The decision model's probability that one of the lookup's candidates is what's needed
    /// (one minus "none"). The same for every result of a lookup; what an ambient signal needs.
    public var answered: Double?
    /// Which decision model and prompt gave `probability` (`Decider.modelID`), so journaled
    /// outcomes from different models can be told apart.
    public var decider: String?

    public init(cosine: Double, daysSinceTouched: Double, recallIntent: Bool = false, probability: Double? = nil,
                answered: Double? = nil, decider: String? = nil) {
        self.cosine = cosine
        self.daysSinceTouched = daysSinceTouched
        self.recallIntent = recallIntent
        self.probability = probability
        self.answered = answered
        self.decider = decider
    }

    // Journal rows from before the decision model carry other measurements and no probability.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            cosine: try c.decode(Double.self, forKey: .cosine),
            daysSinceTouched: try c.decode(Double.self, forKey: .daysSinceTouched),
            recallIntent: try c.decodeIfPresent(Bool.self, forKey: .recallIntent) ?? false,
            probability: try c.decodeIfPresent(Double.self, forKey: .probability),
            answered: try c.decodeIfPresent(Double.self, forKey: .answered),
            decider: try c.decodeIfPresent(String.self, forKey: .decider)
        )
    }
}

public struct Suggestion: Sendable, Codable, Hashable, Identifiable {
    public var id: Int64 { item.id }
    public let item: Item
    /// The part that matched: a chunk, a PDF page, the image.
    public let unit: Unit
    /// "Mentions Dana Ruiz · last opened March 2024 · page 3"
    public let reason: String
    /// A short excerpt of the matching text.
    public let snippet: String
    /// Discovery order: how strongly retrieval found it. Never shown as confidence.
    public let score: Double
    /// 0–1: the decision model's probability that this is what you need. 0 when no decision
    /// ran (no model yet, or a picture with no words); see `decided`.
    public let confidence: Double
    public let features: Features
    /// When the context asks for a value ("what was the wifi password?"), the unit's line
    /// that holds it.
    public let line: MatchedLine?
    public let evidence: PassageEvidence?

    /// Whether the decision model judged it. Undecided results are listed when asked for, but
    /// show no confidence and never signal on their own.
    public var decided: Bool { features.probability != nil }

    public init(item: Item, unit: Unit, reason: String, snippet: String, score: Double, confidence: Double, features: Features,
                line: MatchedLine? = nil, evidence: PassageEvidence? = nil) {
        self.item = item
        self.unit = unit
        self.reason = reason
        self.snippet = snippet
        self.score = score
        self.confidence = confidence
        self.features = features
        self.line = line
        self.evidence = evidence
    }

    /// The same result with the decision model's probability for it, and that some candidate
    /// of the lookup is what's needed, as decided by `decider` (its `modelID`).
    func withProbability(_ probability: Double, answered: Double, decider: String) -> Suggestion {
        var features = features
        features.probability = probability
        features.answered = answered
        features.decider = decider
        return Suggestion(item: item, unit: unit, reason: reason, snippet: snippet, score: score, confidence: probability,
                          features: features, line: line, evidence: evidence)
    }
}

public struct RecallResponse: Sendable, Codable {
    public var suggestions: [Suggestion]
    public var query: Query.Summary
    public var milliseconds: Double
    public var timings: SearchTimings? = nil
    public var retrieval: RetrievalDiagnostics? = nil
    /// The decision model's probability that none of the candidates is what's needed; nil
    /// when no decision ran.
    public var unanswered: Double? = nil

    /// The best suggestion's confidence, or 0.
    public var confidence: Double { suggestions.first?.confidence ?? 0 }
}

extension Query {
    public struct Summary: Sendable, Codable, Equatable {
        public var entities: [String]
        public var rareTerms: [String]
        public var denseCharacters: Int
    }

    var summary: Summary { Summary(entities: entities + contextEntities + identifiers, rareTerms: rareTerms, denseCharacters: dense.count) }
}

/// Tunable numbers for discovery: how candidates are found and fused. Which of them answers
/// is the decision model's job, not a setting.
public struct RankingSettings: Sendable, Codable, Equatable {
    public var rrfK = 60.0
    public var textWeight = 1.0
    public var imageWeight = 0.9
    public var fullTextWeight = 0.8
    /// When the window shows a picture and has words too, the picture's share of the blended
    /// query vector. With no words, the picture is the whole query.
    public var pictureWeight = 0.7

    public init() {}
}

/// Finds what you already have that relates to a context. Retrieval discovers candidates and
/// reads their exact passages; the decision model then judges which one answers, or none, and
/// its probability is both the order and the confidence.
public struct Recall: Sendable {
    public let store: IndexStore
    public let vectors: VectorIndex
    public let embedder: any Embedder
    /// Nil until its model is installed: results are then listed undecided.
    public var decider: (any Decider)?
    public var settings = RankingSettings()
    private let pictures = PictureCache()
    private let passages = PassageSelector()
    private let messages: MessagesReader?

    public init(store: IndexStore, vectors: VectorIndex, embedder: any Embedder, messages: MessagesReader? = nil,
                decider: (any Decider)? = nil) {
        self.store = store
        self.vectors = vectors
        self.embedder = embedder
        self.messages = messages
        self.decider = decider
    }

    public func run(_ request: RecallRequest, now: Date = Date()) async throws -> RecallResponse {
        try Task.checkCancellation()
        let started = Date()
        let prepared = ContinuousClock.now
        let context = request.context
        let picture = try await pictureVector(context)
        // A picture's window title is usually just its file name, which says nothing.
        var textContext = context
        if picture != nil, let path = context.documentPath, Self.isFileName(context.windowTitle, of: path, app: context.appName) {
            textContext.windowTitle = ""
        }
        let plan = RetrievalPlan(textContext)
        let query = QueryBuilder.build(plan.primary) { terms in
            (try? store.documentFrequencies(terms)) ?? ([:], 0)
        }
        let lexical = try LexicalTerms(query.dense, store: store)
        let ranksPassages = plan.hasActiveText && embedder.supportsPassageRefinement
        SearchTrace.current?.record(.preparation, since: prepared)
        try Task.checkCancellation()
        let hasText = query.dense.count >= 12 || !query.entities.isEmpty
            || ((plan.hasActiveText || context.origin == .text) && !query.dense.isEmpty)
        guard hasText || picture != nil else {
            return RecallResponse(suggestions: [], query: query.summary, milliseconds: 0)
        }
        // One query vector: the words, the picture, or both blended. Text and image vectors share
        // one space, so the picture finds other pictures of the same thing and text about it.
        var queryVector: [Float]
        if hasText {
            queryVector = try await embedder.embed(queries: [query.dense])[0]
            if let picture {
                let w = Float(settings.pictureWeight)
                queryVector = VectorMath.normalized(zip(queryVector, picture).map { (1 - w) * $0 + w * $1 })
            }
        } else {
            queryVector = picture!
        }
        try Task.checkCancellation()

        // Candidates: three ranked lists, fused by rank.
        let vectorStarted = ContinuousClock.now
        let textHits = vectors.search(queryVector, kind: .text, limit: plan.hasActiveText ? 2_048 : 200)
        try Task.checkCancellation()
        let imageHits = vectors.search(queryVector, kind: .image, limit: 60)
        SearchTrace.current?.record(.vector, since: vectorStarted)
        try Task.checkCancellation()
        let fullTextStarted = ContinuousClock.now
        let fullTextHits = try store.fullText(query.fullText, limit: plan.hasActiveText ? 1_024 : 100)
        let scopedHits = try store.messageHits(query.fullText, chatIDs: Array((context.messageChatIDs ?? []).prefix(8)), limit: 128)
        // Independent temporal coverage within a resolved conversation. Years of
        // repeated wording cannot consume every slot before a new discussion is read.
        // This discovers candidates; age never raises their final evidence score.
        var recentHits = plan.hasActiveText
            ? try store.messageHits(query.fullText, chatIDs: Array((context.messageChatIDs ?? []).prefix(8)), limit: 32, newestFirst: true) : []
        if plan.hasActiveText {
            recentHits += try store.messageHits(lexical.phraseQuery, chatIDs: nil, limit: 32, newestFirst: true)
        }
        // Surroundings discover candidates independently, with a bounded secondary budget.
        // Their scores never substitute for relevance to the primary question.
        let surroundingQuery = plan.surrounding.map { QueryBuilder.build($0) { (try? store.documentFrequencies($0)) ?? ([:], 0) } }
        let surroundingHits = try surroundingQuery.map { try store.fullText($0.fullText, limit: 64) } ?? []
        SearchTrace.current?.record(.fullText, since: fullTextStarted)
        try Task.checkCancellation()
        let rankingStarted = ContinuousClock.now
        defer { SearchTrace.current?.record(.ranking, since: rankingStarted) }

        var fused: [Int64: Double] = [:]
        var cosine: [Int64: Double] = [:]
        func add(_ ids: [Int64], weight: Double) {
            for (rank, id) in ids.enumerated() { fused[id, default: 0] += weight / (settings.rrfK + Double(rank + 1)) }
        }
        add(textHits.map(\.id), weight: settings.textWeight)
        add(imageHits.map(\.id), weight: settings.imageWeight)
        add(fullTextHits.map(\.unitID), weight: settings.fullTextWeight)
        add(scopedHits.map(\.unitID), weight: settings.fullTextWeight)
        add(recentHits.map(\.unitID), weight: settings.fullTextWeight)
        add(surroundingHits.map(\.unitID), weight: settings.fullTextWeight * 0.25)
        for hit in textHits + imageHits { cosine[hit.id] = Double(hit.score) }

        var units = try store.units(ids: Array(fused.keys))
        var items = try store.items(ids: Array(Set(units.values.map(\.itemID))))
        let neverShow = try store.neverShown()
        let excluded = Set(request.exclude)

        // Discussion expansion works before the expensive passage shortlist. It uses
        // source identity and bounded indexed neighbours, not the window title.
        var connections: [Int64: [Int64]] = [:]
        let anchors = (recentHits.map(\.unitID) + scopedHits.map(\.unitID) + fullTextHits.map(\.unitID) + textHits.map(\.id))
        var seenAnchors = Set<Int64>()
        for id in anchors where plan.hasActiveText && seenAnchors.count < 24 {
            guard let unit = units[id], let item = items[unit.itemID], item.kind == .message,
                  !excluded.contains(item.id), !neverShow.contains(item.id),
                  lexical.coverage(unit.text) > 0, seenAnchors.insert(item.id).inserted else { continue }
            let neighbours = try store.messageNeighbours(of: item)
            let connectionVectors = try store.vectors(unitIDs: neighbours.map { $0.1.id } + [unit.id])
            for (neighbour, text) in neighbours {
                guard neighbour.id != item.id, !excluded.contains(neighbour.id), !neverShow.contains(neighbour.id),
                      abs(neighbour.created.timeIntervalSince(item.created)) <= 86_400,
                      DiscussionLink.connects(unit, text, vectors: connectionVectors) else { continue }
                units[text.id] = text
                items[neighbour.id] = neighbour
                fused[text.id] = max(fused[text.id] ?? 0, (fused[id] ?? 0) * 0.8)
                connections[text.id, default: []].append(id)
            }
        }
        // Every discovered unit gets its actual primary-query similarity, including
        // lexical/scoped/expanded hits outside the vector top-k.
        for (id, vector) in try store.vectors(unitIDs: Array(fused.keys.filter { cosine[$0] == nil })) {
            cosine[id] = Double(VectorMath.dot(queryVector, vector))
        }

        // Roll units up to items. The best-fused unit represents the item; the evidence is all
        // of its matched units: a photo's picture and its words are separate units.
        struct Candidate {
            var item: Item
            var unit: Unit
            var fused: Double
            var cosine: Double
            var texts: [String]
        }
        var candidates: [Int64: Candidate] = [:]
        for (id, score) in fused {
            guard let unit = units[id], let item = items[unit.itemID] else { continue }
            var candidate = candidates[item.id] ?? Candidate(item: item, unit: unit, fused: score, cosine: 0, texts: [])
            if score > candidate.fused { candidate.unit = unit; candidate.fused = score }
            candidate.cosine = max(candidate.cosine, cosine[id] ?? 0)
            if !unit.text.isEmpty { candidate.texts.append(unit.text) }
            candidates[item.id] = candidate
        }

        let passageQuestion = Question(plan.primary)

        // Discovery order only: it decides which candidates get their passages read and reach
        // the decision model. It never claims that anything answers.
        var scored: [(candidate: Candidate, score: Double, features: Features, matched: String?)] = []
        for var candidate in candidates.values {
            let item = candidate.item
            // Hard filters: what's open and what you've ruled out.
            if item.path == context.documentPath || excluded.contains(item.id) || neverShow.contains(item.id) { continue }
            if !ranksPassages, item.source == .file,
               let spotlight = LastUsed.date(path: item.path),
               spotlight > (item.lastUsed ?? .distantPast) {
                candidate.item.lastUsed = spotlight
                try? store.touch(path: item.path, at: spotlight)
            }
            let days = max(0, now.timeIntervalSince(candidate.item.lastTouched) / 86_400)
            let haystack = (candidate.unit.text + " " + item.title).lowercased()
            let matched = query.matchable.first { haystack.contains($0) } ?? query.contextMatchable.first { haystack.contains($0) }
            let unitCosine = cosine[candidate.unit.id] ?? 0
            let features = Features(cosine: unitCosine, daysSinceTouched: days, recallIntent: query.recallIntent)
            // A reply can omit every topic word. Its connected source supplies a
            // discovery cue only; the combined verbatim passage is what gets judged.
            let supportUnits = (connections[candidate.unit.id] ?? []).compactMap { units[$0] }
            let discoveryCosine = max(candidate.cosine, supportUnits.compactMap { cosine[$0.id] }.max() ?? 0)
            let discoveryCoverage = lexical.coverage((candidate.texts + supportUnits.map(\.text) + [item.title]).joined(separator: "\n"))
            // Rank fusion chose the candidates; their order is their own evidence.
            let score = max(0, discoveryCosine) * (1 + discoveryCoverage)
            scored.append((candidate, score, features, matched))
        }
        scored.sort { $0.score == $1.score ? $0.candidate.item.id < $1.candidate.item.id : $0.score > $1.score }

        let question = passageQuestion
        let terms = query.matchable + query.contextMatchable + query.rareTerms
        let broad = scored.map { entry in
            Suggestion(item: entry.candidate.item, unit: entry.candidate.unit,
                       reason: Self.reason(entry.candidate.item, unit: entry.candidate.unit, matched: entry.matched, query: query, now: now),
                       snippet: Self.snippet(entry.candidate.unit.text, around: entry.matched ?? query.rareTerms.first),
                       score: entry.score, confidence: 0, features: entry.features)
        }
        // Index-only lookups can collapse identical whole windows. With live source
        // provenance, equal text from distinct messages must reach identity dedup.
        var windows: Set<String> = []
        let distinct = broad.filter { result in
            guard messages == nil, result.unit.kind == .text, let chat = result.item.message?.chatID else { return true }
            return windows.insert("\(chat)\u{0}\(result.unit.text)").inserted
        }
        // Reserve passage-reading capacity for independently discovered scoped discussions
        // and connected follow-ups. One prolific global route cannot consume every slot.
        var shortlist: [Suggestion] = []
        var admittedIDs = Set<Int64>()
        let discoveryVectors = ranksPassages ? try store.vectors(unitIDs: distinct.map(\.unit.id)) : [:]
        var redundancy: [Int64: Double] = [:]
        func admit(_ results: [Suggestion], limit: Int) throws {
            let top = max(results.first?.score ?? 1, .leastNormalMagnitude)
            for _ in 0..<limit where shortlist.count < PassageSelector.maximumCandidates {
                try Task.checkCancellation()
                let next = results.filter { !admittedIDs.contains($0.id) }.max { a, b in
                    func value(_ candidate: Suggestion) -> Double {
                        guard ranksPassages else { return candidate.score }
                        return 0.7 * candidate.score / top - 0.3 * (redundancy[candidate.unit.id] ?? 0)
                    }
                    let left = value(a), right = value(b)
                    return left == right ? a.id > b.id : left < right
                }
                guard let next else { break }
                admittedIDs.insert(next.id)
                shortlist.append(next)
                if let selected = discoveryVectors[next.unit.id] {
                    for (id, vector) in discoveryVectors {
                        redundancy[id] = max(redundancy[id] ?? 0, Double(VectorMath.dot(selected, vector)))
                    }
                }
            }
        }
        let chats = Set(context.messageChatIDs ?? [])
        if plan.hasActiveText {
            // The open conversation gets its own route rather than a score multiplier, and
            // global coverage comes first.
            try admit(distinct, limit: 8)
            if ranksPassages {
                // Aggregate topic similarity can bury the only match for a specific
                // clue. Give each of the rarest query terms bounded representation.
                let tokens = Dictionary(uniqueKeysWithValues: distinct.map {
                    ($0.id, Set(LexicalTerms.tokens($0.unit.text + " " + $0.item.title)))
                })
                let clues = lexical.terms.sorted {
                    let left = lexical.weights[$0] ?? 0, right = lexical.weights[$1] ?? 0
                    return left == right ? $0 < $1 : left > right
                }.prefix(8)
                for clue in clues {
                    let represented = shortlist.filter { tokens[$0.id]?.contains(clue) == true }.count
                    try admit(distinct.filter { tokens[$0.id]?.contains(clue) == true }, limit: max(0, 2 - represented))
                }
            }
            let recentIDs = Set(recentHits.compactMap { units[$0.unitID]?.itemID })
            try admit(distinct.filter { recentIDs.contains($0.id) }, limit: 8)
            try admit(distinct.filter { chats.contains($0.item.message?.chatID ?? -1) }, limit: 8)
            try admit(distinct.filter { connections[$0.unit.id] != nil }, limit: 8)
        }
        try admit(distinct, limit: PassageSelector.maximumCandidates - shortlist.count)
        // Bound source reads and inference, then collapse identical evidence. Related results
        // and typed search read the same passages.
        var ordered: [Suggestion]
        if embedder.supportsPassageRefinement {
            ordered = try await passages.select(shortlist, query: queryVector, embedder: embedder,
                                                store: store, messages: messages, excluded: excluded,
                                                question: question, terms: terms, lexical: ranksPassages ? lexical : nil,
                                                connections: connections)
        } else {
            // For file-to-file similarity, the indexed unit itself is the exact text
            // scored by the stored vector. Preserve that evidence without new inference.
            let unchanged = try store.unchangedVisibleUnits(distinct.map { ($0.item, $0.unit) })
            ordered = distinct.compactMap { result in
                guard unchanged.contains(result.unit.id) else { return nil }
                guard result.unit.kind == .text, result.item.kind != .image, !result.unit.text.isEmpty else { return result }
                let evidence = PassageEvidence(text: result.unit.text, sources: [
                    .init(itemID: result.id, unitID: result.unit.id, message: nil, modified: result.item.modified,
                          utf16Location: 0, utf16Length: (result.unit.text as NSString).length),
                ], cosine: result.features.cosine)
                return Suggestion(item: result.item, unit: result.unit, reason: result.reason, snippet: result.snippet,
                                  score: result.score, confidence: 0, features: result.features,
                                  line: result.line, evidence: evidence)
            }
        }

        // The decision: which of the leading candidates is what's needed, or none. Its
        // probabilities order the results and are their confidence. A picture with no words
        // gives the model nothing to read, so it stays undecided.
        var unanswered: Double?
        if let decider, hasText, !ordered.isEmpty {
            let pool = try diversePool(ordered, count: DecisionFraming.candidates, openConversations: chats)
            let decisionStarted = ContinuousClock.now
            do {
                let decision = DecisionFraming.request(textContext, plan: plan, query: query, candidates: pool,
                                                       openConversations: chats, texts: try readable(pool))
                let probabilities = try await decider.decide(decision)
                guard probabilities.count == pool.count + 1 else { throw DecisionError.invalid("wrong number of answers") }
                unanswered = probabilities[pool.count]
                ordered = zip(pool, probabilities).map { $0.withProbability($1, answered: 1 - probabilities[pool.count], decider: decider.modelID) }
                    .sorted { $0.confidence == $1.confidence ? $0.score > $1.score : $0.confidence > $1.confidence }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // An unavailable or failing model leaves the results undecided: listed in
                // discovery order, with no confidence and no ambient signal.
            }
            SearchTrace.current?.record(.decision, since: decisionStarted)
            // Hiding, unsending or editing a source while the model read it drops that result.
            ordered = try PassageSelector.revalidate(ordered, store: store, messages: messages, excluded: excluded)
        }

        let suggestions = ordered.prefix(request.limit).map { result in
            // Passage refinement already formats its verified source range. Images and
            // stored-vector lookups need the original unit's line, but only after
            // selection: formatting every discovery candidate cannot affect ranking.
            guard let question, result.evidence == nil || !embedder.supportsPassageRefinement else { return result }
            return Suggestion(item: result.item, unit: result.unit, reason: result.reason, snippet: result.snippet,
                              score: result.score, confidence: result.confidence, features: result.features,
                              line: MatchedLine.find(in: result.unit.text, for: question, terms: terms),
                              evidence: result.evidence)
        }
        try Task.checkCancellation()
        return RecallResponse(
            suggestions: Array(suggestions), query: query.summary, milliseconds: Date().timeIntervalSince(started) * 1000,
            retrieval: RetrievalDiagnostics(candidateItemIDs: candidates.keys.sorted(), shortlistedItemIDs: shortlist.map(\.id),
                                            rankedItemIDs: distinct.map(\.id), refinedItemIDs: ordered.map(\.id)),
            unanswered: unanswered
        )
    }

    /// The candidates the decision model reads. The same text twice (a screenshot sent to two
    /// conversations) is one candidate, kept from the open conversation. Then the strongest
    /// first and the rest by maximal marginal relevance, so a run of near-identical passages (a
    /// year of receipts) takes one slot, not all of them, and every distinct kind of evidence
    /// retrieval found gets read.
    func diversePool(_ ranked: [Suggestion], count: Int, openConversations: Set<Int64> = []) throws -> [Suggestion] {
        var kept: [String: Int] = [:]
        var unique: [Suggestion] = []
        for result in ranked {
            let text = (result.evidence?.text ?? result.unit.text).lowercased()
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !text.isEmpty else { unique.append(result); continue }
            if let index = kept[text] {
                let open = { (s: Suggestion) in openConversations.contains(s.item.message?.chatID ?? -1) }
                if open(result), !open(unique[index]) { unique[index] = result }
                continue
            }
            kept[text] = unique.count
            unique.append(result)
        }
        let ranked = unique
        guard ranked.count > count else { return ranked }
        let stored = try store.vectors(unitIDs: ranked.map(\.unit.id))
        let passageVectors = passages.vectors(for: ranked)
        let vectors = ranked.map { passageVectors[$0.id] ?? stored[$0.unit.id] }
        let top = max(ranked.first?.score ?? 1, .leastNormalMagnitude)
        var chosen: [Int] = []
        var nearest = [Double](repeating: 0, count: ranked.count)
        while chosen.count < count {
            var best: (index: Int, value: Double)?
            for index in ranked.indices where !chosen.contains(index) {
                let value = 0.5 * ranked[index].score / top - 0.5 * nearest[index]
                if best == nil || value > best!.value { best = (index, value) }
            }
            guard let best else { break }
            chosen.append(best.index)
            guard let selected = vectors[best.index] else { continue }
            for index in ranked.indices {
                if let vector = vectors[index], vector.count == selected.count {
                    nearest[index] = max(nearest[index], Double(VectorMath.dot(selected, vector)))
                }
            }
        }
        return chosen.map { ranked[$0] }
    }

    /// What the decision model should read for each candidate when the matched passage alone
    /// is too little: a picture's recognized text (its picture and its words are separate
    /// units), or the stretch of a document around a short passage.
    func readable(_ pool: [Suggestion]) throws -> [Int64: String] {
        var texts: [Int64: String] = [:]
        for result in pool where result.item.source != .messages || result.item.kind == .image {
            let passage = result.evidence?.text ?? result.unit.text
            if passage.isEmpty || result.unit.kind == .image {
                // A Messages photo's .chunk(0) is the conversation around it, not the picture's
                // own text, and isn't revalidated here: only its recognized text speaks for it.
                let words = try store.units(itemID: result.item.id).filter {
                    $0.unit.kind == .text && !$0.unit.text.isEmpty
                        && !(result.item.source == .messages && $0.unit.locator == .chunk(0))
                }.map(\.unit.text).joined(separator: "\n")
                if !words.isEmpty { texts[result.id] = String(words.prefix(500)) }
            } else if passage.count < 200, let range = result.unit.text.range(of: passage) {
                // Center a window of about 500 characters on the passage.
                let source = result.unit.text
                let before = source[..<range.lowerBound].suffix(max(0, (500 - passage.count) / 2))
                let after = source[range.upperBound...].prefix(max(0, 500 - passage.count - before.count))
                texts[result.id] = (before.startIndex == source.startIndex ? "" : "…") + before + passage + after
                    + (after.endIndex == source.endIndex ? "" : "…")
            }
        }
        return texts
    }

    /// The vector of the picture the window shows: the one it was indexed with, or, for a
    /// picture that isn't indexed (yet), one embedded now. Nil when the window shows no
    /// picture, the embedder can't see images, or the file can't be read.
    func pictureVector(_ context: ContextSnapshot) async throws -> [Float]? {
        guard context.showsPicture, embedder.supportsImages, let path = context.documentPath else { return nil }
        if let item = try store.item(path: path),
           let unit = try store.units(itemID: item.id).first(where: { $0.unit.kind == .image }),
           unit.vector.count == embedder.dimension {
            return unit.vector
        }
        let url = URL(filePath: path)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let vector = pictures.vector(path: path, modified: modified) { return vector }
        guard let image = Extractor.loadImage(url), Extractor.isWorthIndexing(image),
              let vector = try await embedder.embed(images: [image]).first, vector.count == embedder.dimension else { return nil }
        pictures.keep(vector, path: path, modified: modified)
        return vector
    }

    /// Whether a window title is just the file's name ("IMG_2041.HEIC", "IMG_2041").
    static func isFileName(_ title: String, of path: String, app: String) -> Bool {
        let title = QueryBuilder.cleanTitle(title, app: app).lowercased()
        let name = (path as NSString).lastPathComponent.lowercased()
        return title.isEmpty || title == name || title == (name as NSString).deletingPathExtension
    }

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 })
    }

    /// One line on why: what matched, when you last had it, and where in it.
    static func reason(_ item: Item, unit: Unit, matched: String?, query: Query, now: Date) -> String {
        var parts: [String] = []
        if let matched {
            let original = (query.entities + query.contextEntities + query.identifiers).first { $0.lowercased() == matched } ?? matched
            parts.append("Mentions \(original)")
        } else if let term = query.rareTerms.first(where: { (unit.text + item.title).lowercased().contains($0) }) {
            parts.append("Also about “\(term)”")
        } else {
            parts.append(unit.kind == .image ? "Looks related" : "Related")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        if let used = item.lastUsed, used > item.modified {
            parts.append("last opened \(formatter.string(from: used))")
        } else {
            parts.append("from \(formatter.string(from: item.modified))")
        }
        if let page = unit.locator.page { parts.append("page \(page)") }
        return parts.joined(separator: " · ")
    }

    /// About 160 characters of the unit's text, around the matched word if there is one.
    static func snippet(_ text: String, around term: String?) -> String {
        let flat = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard flat.count > 160 else { return flat }
        if let term, let range = flat.range(of: term, options: .caseInsensitive) {
            let start = flat.index(range.lowerBound, offsetBy: -60, limitedBy: flat.startIndex) ?? flat.startIndex
            let end = flat.index(start, offsetBy: 160, limitedBy: flat.endIndex) ?? flat.endIndex
            return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
        }
        return String(flat.prefix(160)) + "…"
    }
}

/// The last picture embedded for a context that wasn't in the index, so staying on it
/// doesn't run the vision model on every look. Memory only, one entry.
final class PictureCache: Sendable {
    private struct Entry {
        let path: String
        let modified: Date?
        let vector: [Float]
    }

    private let entry = Mutex<Entry?>(nil)

    func vector(path: String, modified: Date?) -> [Float]? {
        entry.withLock { $0?.path == path && $0?.modified == modified ? $0?.vector : nil }
    }

    func keep(_ vector: [Float], path: String, modified: Date?) {
        entry.withLock { $0 = Entry(path: path, modified: modified, vector: vector) }
    }
}
