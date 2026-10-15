import Foundation

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
    /// Found by both the vector and full-text searches.
    public var agreement: Bool
    /// A person, organization or identifier from the context appears in it.
    public var entityHit: Bool
    public var daysSinceTouched: Double
    public var fused: Double
    public var forgotten: Double
    public var novelty: Double

    public init(cosine: Double, zScore: Double, agreement: Bool, entityHit: Bool, daysSinceTouched: Double, fused: Double, forgotten: Double, novelty: Double) {
        self.cosine = cosine
        self.zScore = zScore
        self.agreement = agreement
        self.entityHit = entityHit
        self.daysSinceTouched = daysSinceTouched
        self.fused = fused
        self.forgotten = forgotten
        self.novelty = novelty
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

    public init(item: Item, unit: Unit, reason: String, snippet: String, score: Double, confidence: Double, features: Features) {
        self.item = item
        self.unit = unit
        self.reason = reason
        self.snippet = snippet
        self.score = score
        self.confidence = confidence
        self.features = features
    }
}

public struct RecallResponse: Sendable, Codable {
    public var suggestions: [Suggestion]
    public var query: Query.Summary
    public var milliseconds: Double

    /// The best suggestion's confidence, or 0.
    public var confidence: Double { suggestions.first?.confidence ?? 0 }
}

extension Query {
    public struct Summary: Sendable, Codable, Equatable {
        public var entities: [String]
        public var rareTerms: [String]
        public var denseCharacters: Int
    }

    var summary: Summary { Summary(entities: entities + identifiers, rareTerms: rareTerms, denseCharacters: dense.count) }
}

/// Tunable numbers for ranking. The defaults are starting points; the journal and the eval
/// harness are how they get better.
public struct RankingSettings: Sendable, Codable, Equatable {
    /// Anything opened or changed this recently is something you remember.
    public var recentDays = 3.0
    /// Where "forgotten" reaches full weight.
    public var forgottenDays = 90.0
    public var rrfK = 60.0
    public var textWeight = 1.0
    public var imageWeight = 0.9
    public var fullTextWeight = 0.8
    public var entityBoost = 1.5
    public var sameFolderPenalty = 0.6
    public var sameTitlePenalty = 0.5
    /// MMR: 1 is pure relevance, 0 pure variety.
    public var diversity = 0.7

    public init() {}
}

/// Finds what you already have that relates to a context, and ranks it for being relevant,
/// forgotten, new and varied.
public struct Recall: Sendable {
    public let store: IndexStore
    public let vectors: VectorIndex
    public let embedder: any Embedder
    public var settings = RankingSettings()

    public init(store: IndexStore, vectors: VectorIndex, embedder: any Embedder) {
        self.store = store
        self.vectors = vectors
        self.embedder = embedder
    }

    public func run(_ request: RecallRequest, now: Date = Date()) async throws -> RecallResponse {
        let started = Date()
        let context = request.context
        let query = QueryBuilder.build(context) { terms in
            (try? store.documentFrequencies(terms)) ?? ([:], 0)
        }
        guard query.dense.count >= 12 || !query.entities.isEmpty else {
            return RecallResponse(suggestions: [], query: query.summary, milliseconds: 0)
        }
        let queryVector = try await embedder.embed(queries: [query.dense])[0]

        // Candidates: three ranked lists, fused by rank.
        let textHits = vectors.search(queryVector, kind: .text, limit: 200)
        let imageHits = vectors.search(queryVector, kind: .image, limit: 60)
        let fullTextHits = (try? store.fullText(query.fullText, limit: 100)) ?? []

        var fused: [Int64: Double] = [:]
        var cosine: [Int64: Double] = [:]
        func add(_ ids: [Int64], weight: Double) {
            for (rank, id) in ids.enumerated() { fused[id, default: 0] += weight / (settings.rrfK + Double(rank + 1)) }
        }
        add(textHits.map(\.id), weight: settings.textWeight)
        add(imageHits.map(\.id), weight: settings.imageWeight)
        add(fullTextHits.map(\.unitID), weight: settings.fullTextWeight)
        for hit in textHits + imageHits { cosine[hit.id] = Double(hit.score) }
        let fullTextIDs = Set(fullTextHits.map(\.unitID))
        let vectorIDs = Set(textHits.map(\.id) + imageHits.map(\.id))

        // How unusual the best matches are for this context: z-scores within each list.
        let textStats = Stats(textHits.map { Double($0.score) })
        let imageStats = Stats(imageHits.map { Double($0.score) })

        let units = try store.units(ids: Array(fused.keys))
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

        let titleWords = Self.words(QueryBuilder.cleanTitle(context.windowTitle, app: context.appName))
        let documentFolder = context.documentPath.map { ($0 as NSString).deletingLastPathComponent }
        let matchable = query.matchable

        var scored: [(candidate: Candidate, score: Double, features: Features, matched: String?)] = []
        for var candidate in candidates.values {
            let item = candidate.item
            // Hard filters: what's open, what you just touched, what you've ruled out.
            if item.path == context.documentPath || excluded.contains(item.id) || neverShow.contains(item.id) { continue }
            if item.source == .file, let spotlight = LastUsed.date(path: item.path),
               spotlight > (item.lastUsed ?? .distantPast) {
                candidate.item.lastUsed = spotlight
                try? store.touch(path: item.path, at: spotlight)
            }
            let days = max(0, now.timeIntervalSince(candidate.item.lastTouched) / 86_400)
            if days < settings.recentDays { continue }

            let forgotten = 0.25 + 0.75 * min(1, log(days / settings.recentDays) / log(settings.forgottenDays / settings.recentDays))
            var novelty = 1.0
            if let documentFolder, item.folder == documentFolder { novelty *= settings.sameFolderPenalty }
            let itemWords = Self.words((item.title as NSString).deletingPathExtension)
            if !titleWords.isEmpty, !itemWords.isEmpty,
               Double(titleWords.intersection(itemWords).count) / Double(itemWords.count) >= 0.6 {
                novelty *= settings.sameTitlePenalty
            }
            let haystack = (candidate.unit.text + " " + item.title).lowercased()
            let matched = matchable.first { haystack.contains($0) }
            let relevance = candidate.fused + min(candidate.extra, candidate.fused * 0.5)
            let rankScore = relevance * forgotten * novelty * (matched != nil ? settings.entityBoost : 1)

            let unitCosine = cosine[candidate.unit.id] ?? 0
            let stats = candidate.unit.kind == .image ? imageStats : textStats
            let features = Features(
                cosine: unitCosine,
                zScore: cosine[candidate.unit.id] == nil ? 0 : stats.z(unitCosine),
                agreement: vectorIDs.contains(candidate.unit.id) && fullTextIDs.contains(candidate.unit.id),
                entityHit: matched != nil,
                daysSinceTouched: days,
                fused: relevance,
                forgotten: forgotten,
                novelty: novelty
            )
            // Rank fusion alone rewards whatever tops each list, however weak (the best image
            // match for a text-only context is usually noise), so weigh in how convincing it is.
            let score = rankScore * (0.25 + Confidence.estimate(features))
            scored.append((candidate, score, features, matched))
        }
        scored.sort { $0.score > $1.score }

        // Variety: maximal marginal relevance over the top few, with a nudge away from a
        // second item from the same folder.
        let pool = Array(scored.prefix(24))
        let poolVectors = (try? store.vectors(unitIDs: pool.map(\.candidate.unit.id))) ?? [:]
        let topScore = pool.first?.score ?? 1
        var chosen: [Int] = []
        var usedFolders: Set<String> = []
        while chosen.count < request.limit {
            var best: (index: Int, value: Double)?
            for (index, entry) in pool.enumerated() where !chosen.contains(index) {
                let folder = entry.candidate.item.folder
                let folderPenalty = !folder.isEmpty && usedFolders.contains(folder) ? 0.85 : 1
                let similarity = chosen.map { other -> Double in
                    guard let a = poolVectors[entry.candidate.unit.id], let b = poolVectors[pool[other].candidate.unit.id] else { return 0 }
                    return Double(VectorMath.dot(a, b))
                }.max() ?? 0
                let value = settings.diversity * folderPenalty * entry.score / topScore - (1 - settings.diversity) * similarity
                if best == nil || value > best!.value { best = (index, value) }
            }
            guard let best else { break }
            chosen.append(best.index)
            let folder = pool[best.index].candidate.item.folder
            if !folder.isEmpty { usedFolders.insert(folder) }
        }

        let suggestions = chosen.map { index -> Suggestion in
            let entry = pool[index]
            return Suggestion(
                item: entry.candidate.item,
                unit: entry.candidate.unit,
                reason: Self.reason(entry.candidate.item, unit: entry.candidate.unit, matched: entry.matched, query: query, now: now),
                snippet: Self.snippet(entry.candidate.unit.text, around: entry.matched ?? query.rareTerms.first),
                score: entry.score,
                confidence: Confidence.estimate(entry.features),
                features: entry.features
            )
        }
        return RecallResponse(
            suggestions: suggestions, query: query.summary, milliseconds: Date().timeIntervalSince(started) * 1000
        )
    }

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 3 })
    }

    /// One line on why: what matched, when you last had it, and where in it.
    static func reason(_ item: Item, unit: Unit, matched: String?, query: Query, now: Date) -> String {
        var parts: [String] = []
        if let matched {
            let original = (query.entities + query.identifiers).first { $0.lowercased() == matched } ?? matched
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
        return 1 / (1 + exp(-logit))
    }
}
