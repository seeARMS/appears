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

/// The measurements behind one suggestion: logged in the journal so the threshold can be
/// fitted later, and shown in debug builds.
public struct Features: Sendable, Codable, Hashable {
    /// Cosine of the best unit to the dense query.
    public var cosine: Double
    /// How far that cosine stands above this context's other candidates, in standard deviations.
    public var zScore: Double
    /// The same part of it was found by both the vector and full-text searches.
    public var agreement: Bool
    /// A person, organization or identifier from the context appears in it.
    public var entityHit: Bool
    public var daysSinceTouched: Double
    public var fused: Double
    public var forgotten: Double
    public var novelty: Double
    /// The context asks your own memory for something ("what was the wifi password again?").
    /// The same for every suggestion in a context.
    public var recallIntent: Bool

    public init(cosine: Double, zScore: Double, agreement: Bool, entityHit: Bool, daysSinceTouched: Double, fused: Double, forgotten: Double, novelty: Double, recallIntent: Bool = false) {
        self.cosine = cosine
        self.zScore = zScore
        self.agreement = agreement
        self.entityHit = entityHit
        self.daysSinceTouched = daysSinceTouched
        self.fused = fused
        self.forgotten = forgotten
        self.novelty = novelty
        self.recallIntent = recallIntent
    }

    // Journal rows written before `recallIntent` existed don't have it.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            cosine: try c.decode(Double.self, forKey: .cosine), zScore: try c.decode(Double.self, forKey: .zScore),
            agreement: try c.decode(Bool.self, forKey: .agreement), entityHit: try c.decode(Bool.self, forKey: .entityHit),
            daysSinceTouched: try c.decode(Double.self, forKey: .daysSinceTouched), fused: try c.decode(Double.self, forKey: .fused),
            forgotten: try c.decode(Double.self, forKey: .forgotten), novelty: try c.decode(Double.self, forKey: .novelty),
            recallIntent: try c.decodeIfPresent(Bool.self, forKey: .recallIntent) ?? false
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
    public let score: Double
    /// 0–1: how sure Appears is that this is worth your attention.
    public let confidence: Double
    public let features: Features
    /// When the context asks for a value ("what was the wifi password?"), the unit's line
    /// that holds it.
    public let line: MatchedLine?
    public let evidence: PassageEvidence?
    /// Refining a longer panel cannot broaden the original first-three ambient gate.
    public let ambientEligible: Bool?

    public init(item: Item, unit: Unit, reason: String, snippet: String, score: Double, confidence: Double, features: Features,
                line: MatchedLine? = nil, evidence: PassageEvidence? = nil, ambientEligible: Bool? = nil) {
        self.item = item
        self.unit = unit
        self.reason = reason
        self.snippet = snippet
        self.score = score
        self.confidence = confidence
        self.features = features
        self.line = line
        self.evidence = evidence
        self.ambientEligible = ambientEligible
    }
}

public struct RecallResponse: Sendable, Codable {
    public var suggestions: [Suggestion]
    public var query: Query.Summary
    public var milliseconds: Double
    public var timings: SearchTimings? = nil

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

/// Tunable numbers for ranking. The defaults are starting points; the journal and the eval
/// harness are how they get better.
public struct RankingSettings: Sendable, Codable, Equatable {
    /// Opened or changed this recently: probably something you remember, so it ranks lower (it
    /// isn't hidden; sometimes it's exactly what you need). Ambient suggestions mostly skip it.
    public var recentDays = 3.0
    /// The forgotten weight of something recent, and of something just past `recentDays`.
    public var recentWeight = 0.35
    /// A recent conversation can answer today's question. Age is only a small ranking
    /// preference for Messages, fading from this weight to 1 over `forgottenDays`.
    public var recentMessageWeight = 0.85
    public var olderWeight = 0.5
    /// Ambient confidence multiplier for recent files and Notes. Messages are exempt.
    public var recentAmbientConfidence = 0.5
    /// Where "forgotten" reaches full weight.
    public var forgottenDays = 90.0
    public var rrfK = 60.0
    public var textWeight = 1.0
    public var imageWeight = 0.9
    public var fullTextWeight = 0.8
    /// A name you're writing to or about (selection, the field you're typing in, the title,
    /// recipients) found in the item.
    public var entityBoost = 1.5
    /// A name found only elsewhere in the window: weaker evidence.
    public var contextEntityBoost = 1.15
    public var sameFolderPenalty = 0.6
    public var sameTitlePenalty = 0.5
    /// MMR: 1 is pure relevance, 0 pure variety.
    public var diversity = 0.7
    /// When the window shows a picture and has words too, the picture's share of the blended
    /// query vector. With no words, the picture is the whole query.
    public var pictureWeight = 0.7

    public init() {}
}

/// Finds what you already have that relates to a context, and ranks it for being relevant,
/// forgotten, new and varied.
public struct Recall: Sendable {
    public let store: IndexStore
    public let vectors: VectorIndex
    public let embedder: any Embedder
    public var settings = RankingSettings()
    private let pictures = PictureCache()
    private let passages = PassageSelector()
    private let messages: MessagesReader?

    public init(store: IndexStore, vectors: VectorIndex, embedder: any Embedder, messages: MessagesReader? = nil) {
        self.store = store
        self.vectors = vectors
        self.embedder = embedder
        self.messages = messages
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
        let query = QueryBuilder.build(textContext) { terms in
            (try? store.documentFrequencies(terms)) ?? ([:], 0)
        }
        SearchTrace.current?.record(.preparation, since: prepared)
        try Task.checkCancellation()
        let hasText = query.dense.count >= 12 || !query.entities.isEmpty
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
        let textHits = vectors.search(queryVector, kind: .text, limit: 200)
        try Task.checkCancellation()
        let imageHits = vectors.search(queryVector, kind: .image, limit: 60)
        SearchTrace.current?.record(.vector, since: vectorStarted)
        try Task.checkCancellation()
        let fullTextStarted = ContinuousClock.now
        let fullTextHits = (try? store.fullText(query.fullText, limit: 100)) ?? []
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
        for hit in textHits + imageHits { cosine[hit.id] = Double(hit.score) }

        // How unusual the best matches are for this context: z-scores within each list.
        let textStats = Stats(textHits.map { Double($0.score) })
        let imageStats = Stats(imageHits.map { Double($0.score) })

        let units = try store.units(ids: Array(fused.keys))
        // Agreement counts per part (a chunk, a page, an image): an image's words are in the
        // full-text index under its OCR text unit, at the same locator.
        func part(_ unit: Unit) -> [String] { [String(unit.itemID), unit.locator.encoded] }
        let fullTextParts = Set(fullTextHits.compactMap { units[$0.unitID].map(part) })
        let items = try store.items(ids: Array(Set(units.values.map(\.itemID))))
        let neverShow = try store.neverShown()
        let excluded = Set(request.exclude)

        // Roll units up to items: the best unit, plus a little for each other matching unit.
        struct Candidate {
            var item: Item
            var unit: Unit
            var fused: Double
            var extra: Double
        }
        var candidates: [Int64: Candidate] = [:]
        for (id, score) in fused {
            guard let unit = units[id], let item = items[unit.itemID] else { continue }
            if var existing = candidates[item.id] {
                if score > existing.fused {
                    existing.extra += existing.fused * 0.1
                    existing.unit = unit
                    existing.fused = score
                } else {
                    existing.extra += score * 0.1
                }
                candidates[item.id] = existing
            } else {
                candidates[item.id] = Candidate(item: item, unit: unit, fused: score, extra: 0)
            }
        }

        // The conversation title and visible history help find candidates, but can make
        // an unrelated message seem confident. When there is a draft, judge Messages
        // against what you're actually writing or selecting instead.
        var messageQuery = query
        var messageCosine = cosine
        var messageTextStats = textStats
        var messageImageStats = imageStats
        var messageFullTextParts = fullTextParts
        var passageQueryVector = queryVector
        var passageQuestion = Question(context)
        if !candidates.isEmpty {
            let draftContext = ContextSnapshot(appName: context.appName, selection: context.selection, focusedText: context.focusedText)
            let draft = QueryBuilder.build(draftContext) { terms in
                (try? store.documentFrequencies(terms)) ?? ([:], 0)
            }
            if draft.dense.count >= 12 {
                // The structured question must come from the same active text as the
                // passage vector. An old question in window history cannot constrain
                // evidence for a different draft, even when both queries encode alike.
                passageQuestion = Question(draftContext)
            }
            if draft.dense.count >= 12, draft.dense != query.dense {
                messageQuery = draft
                let vector = try await embedder.embed(queries: [draft.dense])[0]
                passageQueryVector = vector
                try Task.checkCancellation()
                let text = vectors.search(vector, kind: .text, limit: 200)
                let images = vectors.search(vector, kind: .image, limit: 60)
                messageCosine = Dictionary(uniqueKeysWithValues: (text + images).map { ($0.id, Double($0.score)) })
                messageTextStats = Stats(text.map { Double($0.score) })
                messageImageStats = Stats(images.map { Double($0.score) })
                let hits = (try? store.fullText(draft.fullText, limit: 100)) ?? []
                let matchedUnits = try store.units(ids: hits.map(\.unitID))
                messageFullTextParts = Set(matchedUnits.values.map(part))
            }
        }

        let titleWords = Self.words(QueryBuilder.cleanTitle(context.windowTitle, app: context.appName))
        let documentFolder = context.documentPath.map { ($0 as NSString).deletingLastPathComponent }

        var scored: [(candidate: Candidate, score: Double, features: Features, matched: String?, confidence: Double)] = []
        for var candidate in candidates.values {
            let item = candidate.item
            // Hard filters: what's open and what you've ruled out.
            if item.path == context.documentPath || excluded.contains(item.id) || neverShow.contains(item.id) { continue }
            if item.source == .file, let spotlight = LastUsed.date(path: item.path),
               spotlight > (item.lastUsed ?? .distantPast) {
                candidate.item.lastUsed = spotlight
                try? store.touch(path: item.path, at: spotlight)
            }
            let days = max(0, now.timeIntervalSince(candidate.item.lastTouched) / 86_400)
            let recent = days < settings.recentDays
            let forgotten: Double
            if item.source == .messages {
                forgotten = settings.recentMessageWeight + (1 - settings.recentMessageWeight) * min(1, days / settings.forgottenDays)
            } else {
                forgotten = recent
                    ? settings.recentWeight
                    : settings.olderWeight + (1 - settings.olderWeight) * min(1, log(days / settings.recentDays) / log(settings.forgottenDays / settings.recentDays))
            }
            var novelty = 1.0
            if let documentFolder, item.folder == documentFolder { novelty *= settings.sameFolderPenalty }
            let itemWords = Self.words((item.title as NSString).deletingPathExtension)
            if !titleWords.isEmpty, !itemWords.isEmpty,
               Double(titleWords.intersection(itemWords).count) / Double(itemWords.count) >= 0.6 {
                novelty *= settings.sameTitlePenalty
            }
            let haystack = (candidate.unit.text + " " + item.title).lowercased()
            let strongMatch = query.matchable.first { haystack.contains($0) }
            let contextMatch = strongMatch == nil ? query.contextMatchable.first { haystack.contains($0) } : nil
            let matched = strongMatch ?? contextMatch
            let relevance = candidate.fused + min(candidate.extra, candidate.fused * 0.5)
            let boost = strongMatch != nil ? settings.entityBoost : (contextMatch != nil ? settings.contextEntityBoost : 1)
            let rankScore = relevance * forgotten * novelty * boost

            // The draft is the question for every source. Visible history may discover
            // a candidate, but cannot make a file (or a message) confidently answer an
            // unrelated draft merely because its topic is still on screen.
            let evidence = messageCosine
            let unitCosine = evidence[candidate.unit.id] ?? 0
            let stats = candidate.unit.kind == .image ? messageImageStats : messageTextStats
            let matchedParts = messageFullTextParts
            let entityHit = messageQuery.matchable.contains(where: haystack.contains)
            let features = Features(
                cosine: unitCosine,
                zScore: evidence[candidate.unit.id] == nil ? 0 : stats.z(unitCosine),
                agreement: evidence[candidate.unit.id] != nil && matchedParts.contains(part(candidate.unit)),
                entityHit: entityHit,
                daysSinceTouched: days,
                fused: relevance,
                forgotten: forgotten,
                novelty: novelty,
                recallIntent: query.recallIntent
            )
            // Rank fusion alone rewards whatever tops each list, however weak (the best image
            // match for a text-only context is usually noise), so weigh in how convincing it is.
            let recentFactor = recent && item.source != .messages && request.trigger == .ambient ? settings.recentAmbientConfidence : 1
            var confidence = Confidence.estimate(features) * recentFactor
            if item.source != .messages {
                var surrounding = features
                surrounding.cosine = cosine[candidate.unit.id] ?? 0
                let originalStats = candidate.unit.kind == .image ? imageStats : textStats
                surrounding.zScore = cosine[candidate.unit.id].map(originalStats.z) ?? 0
                surrounding.agreement = cosine[candidate.unit.id] != nil && fullTextParts.contains(part(candidate.unit))
                surrounding.entityHit = strongMatch != nil
                confidence = min(confidence, Confidence.estimate(surrounding) * recentFactor)
            }
            // Recall intent is about the context, not any one item: it makes Appears surer
            // without ranking anything higher.
            var unasked = features
            unasked.recallIntent = false
            let score = rankScore * (0.25 + Confidence.estimate(unasked) * recentFactor)
            scored.append((candidate, score, features, matched, confidence))
        }
        scored.sort { $0.score > $1.score }

        let question = passageQuestion
        let terms = query.matchable + query.contextMatchable + query.rareTerms
        let broad = scored.enumerated().map { position, entry in
            Suggestion(item: entry.candidate.item, unit: entry.candidate.unit,
                       reason: Self.reason(entry.candidate.item, unit: entry.candidate.unit, matched: entry.matched, query: query, now: now),
                       snippet: Self.snippet(entry.candidate.unit.text, around: entry.matched ?? query.rareTerms.first),
                       score: entry.score, confidence: entry.confidence, features: entry.features,
                       line: question.flatMap { MatchedLine.find(in: entry.candidate.unit.text, for: $0, terms: terms) },
                       ambientEligible: request.trigger == .ambient ? position < 3 : nil)
        }
        // Index-only lookups can collapse identical whole windows. With live source
        // provenance, equal text from distinct messages must reach identity dedup.
        var windows: Set<String> = []
        let distinct = broad.filter { result in
            guard messages == nil, result.unit.kind == .text, let chat = result.item.message?.chatID else { return true }
            return windows.insert("\(chat)\u{0}\(result.unit.text)").inserted
        }
        // Bound source reads/inference, then collapse identical evidence before applying
        // the result limit. Both related results and typed search use the same passages.
        let refined: [Suggestion]
        if embedder.supportsPassageRefinement {
            refined = try await passages.select(Array(distinct.prefix(PassageSelector.maximumCandidates)), query: passageQueryVector, embedder: embedder,
                                                 store: store, messages: messages, excluded: excluded,
                                                 question: question, terms: terms)
        } else {
            // For file-to-file similarity, the indexed unit itself is the exact text
            // scored by the stored vector. Preserve that evidence without new inference.
            refined = distinct.map { result in
                guard result.unit.kind == .text, result.item.kind != .image, !result.unit.text.isEmpty else { return result }
                let evidence = PassageEvidence(text: result.unit.text, sources: [
                    .init(itemID: result.id, unitID: result.unit.id, message: nil, modified: result.item.modified,
                          utf16Location: 0, utf16Length: (result.unit.text as NSString).length),
                ], cosine: result.features.cosine)
                return Suggestion(item: result.item, unit: result.unit, reason: result.reason, snippet: result.snippet,
                                  score: result.score, confidence: result.confidence, features: result.features,
                                  line: result.line, evidence: evidence, ambientEligible: result.ambientEligible)
            }
        }

        // Variety: maximal marginal relevance over the top few, with a nudge away from a
        // second item from the same folder.
        let pool = Array(refined.prefix(24))
        let poolVectors = (try? store.vectors(unitIDs: pool.map(\.unit.id))) ?? [:]
        let evidenceVectors = passages.vectors(for: pool)
        let topScore = max(pool.first?.score ?? 1, .leastNormalMagnitude)
        var chosen: [Int] = []
        var usedFolders: Set<String> = []
        while chosen.count < request.limit {
            var best: (index: Int, value: Double)?
            for (index, entry) in pool.enumerated() where !chosen.contains(index) {
                let folder = entry.item.folder
                let folderPenalty = !folder.isEmpty && usedFolders.contains(folder) ? 0.85 : 1
                let similarity = chosen.map { other -> Double in
                    guard let a = evidenceVectors[entry.id] ?? poolVectors[entry.unit.id],
                          let b = evidenceVectors[pool[other].id] ?? poolVectors[pool[other].unit.id] else { return 0 }
                    return Double(VectorMath.dot(a, b))
                }.max() ?? 0
                let value = settings.diversity * folderPenalty * entry.score / topScore - (1 - settings.diversity) * similarity
                if best == nil || value > best!.value { best = (index, value) }
            }
            guard let best else { break }
            chosen.append(best.index)
            let folder = pool[best.index].item.folder
            if !folder.isEmpty { usedFolders.insert(folder) }
        }

        let suggestions = chosen.map { pool[$0] }
        try Task.checkCancellation()
        return RecallResponse(
            suggestions: suggestions, query: query.summary, milliseconds: Date().timeIntervalSince(started) * 1000
        )
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

/// Mean and spread of one list's scores.
struct Stats {
    let mean: Double
    let deviation: Double

    init(_ values: [Double]) {
        guard values.count > 1 else { mean = values.first ?? 0; deviation = 1; return }
        let mean = values.reduce(0, +) / Double(values.count)
        self.mean = mean
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        deviation = max(variance.squareRoot(), 0.01)
    }

    func z(_ value: Double) -> Double { (value - mean) / deviation }
}

/// How sure Appears is that a suggestion is worth interrupting for. Hand-set to start; the
/// plan is to fit these weights to the journal (opened vs. dismissed) once there's enough.
public enum Confidence {
    public static func estimate(_ f: Features) -> Double {
        // EmbeddingGemma 2's cosines run high: unrelated text scores around 0.55–0.65 against
        // a context. What separates a real hit is how far it stands above that context's other
        // candidates (z), then a cosine clearly above the baseline, then an exact name match.
        // Fitted by eye to `appears eval` (demo/scenarios.json): hits had z ≥ 4, negatives ≤ 2.6.
        var logit = -6.5
        logit += 1.1 * min(f.zScore, 6)
        logit += 12 * max(0, f.cosine - 0.62)
        logit += f.agreement ? 0.5 : 0
        logit += f.entityHit ? 1.0 : 0
        logit += 0.4 * (f.forgotten - 0.5)
        logit += f.novelty < 1 ? -0.6 : 0
        // Asking your own memory makes a clear match more likely to be what you're after, but
        // says nothing about whether you have it. So it only adds to a match that already stands
        // out: nothing from z 4 down (negatives that ask peaked at 3.3), the full amount from z 5.
        if f.recallIntent { logit += 1.0 * min(max(f.zScore - 4, 0), 1) }
        return 1 / (1 + exp(-logit))
    }
}
