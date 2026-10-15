import Foundation
import GRDB

/// What happened to a suggestion.
public enum Outcome: String, Sendable, Codable, CaseIterable {
    case opened, previewed, dragged, revealed, copied
    /// "Not useful"
    case dismissed
    /// "Not in this app"
    case muted
    /// "Never show this file"
    case blocked
    /// Shown, and nothing happened before the context changed.
    case ignored

    public var isUseful: Bool { [.opened, .previewed, .dragged, .revealed, .copied].contains(self) }
}

/// One row: Appears had suggestions for a context (shown or, in shadow mode, not).
public struct JournalEntry: Sendable, Codable {
    public struct Shown: Sendable, Codable {
        public var itemID: Int64
        public var unitID: Int64
        public var kind: ItemKind
        public var score: Double
        public var confidence: Double
        public var features: Features

        public init(_ suggestion: Suggestion) {
            itemID = suggestion.item.id
            unitID = suggestion.unit.id
            kind = suggestion.item.kind
            score = suggestion.score
            confidence = suggestion.confidence
            features = suggestion.features
        }
    }

    public enum Mode: String, Sendable, Codable {
        /// Pulled with the hotkey or a click.
        case pull
        /// Ambient, and the glyph changed.
        case ambient
        /// Ambient would have shown this, but only logged it.
        case shadow
    }

    public var mode: Mode
    public var bundleID: String
    public var fingerprint: String
    public var dwellSeconds: Double
    public var suggestions: [Shown]
    /// Only kept by development builds, for labelling while dogfooding. Never in release.
    public var debugContext: String?

    public init(mode: Mode, bundleID: String, fingerprint: String, dwellSeconds: Double, suggestions: [Shown], debugContext: String? = nil) {
        self.mode = mode
        self.bundleID = bundleID
        self.fingerprint = fingerprint
        self.dwellSeconds = dwellSeconds
        self.suggestions = suggestions
        self.debugContext = debugContext
    }
}

public struct JournalStats: Sendable, Codable, Equatable {
    public var days: Int
    public var pulls = 0
    public var ambient = 0
    public var shadow = 0
    public var useful = 0
    public var dismissed = 0
    public var ignored = 0
    /// Pulls where the first suggestion was used, of pulls with any outcome.
    public var pullPrecisionAt1: Double?
    /// Pulls where any suggestion was used.
    public var pullPrecisionAt3: Double?
    /// Shadow suggestions that turned out to be what a later pull in the same context opened.
    public var shadowPrecision: Double?
    public var ambientPrecision: Double?

    public var usefulPerDay: Double { Double(useful) / Double(max(days, 1)) }
}

/// The log of suggestions and what you did with them, `journal.sqlite`. It holds item ids,
/// scores and outcomes, and a salted fingerprint of each context, never the context's text
/// (except in development builds, which can keep a snippet for 14 days).
public final class Journal: Sendable {
    private let pool: DatabasePool

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        pool = try DatabasePool(path: url.path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE entry (
                    id INTEGER PRIMARY KEY,
                    at REAL NOT NULL,
                    mode TEXT NOT NULL,
                    bundle_id TEXT NOT NULL,
                    fingerprint TEXT NOT NULL,
                    dwell REAL NOT NULL,
                    suggestions TEXT NOT NULL,
                    debug_context TEXT
                );
                CREATE INDEX entry_fingerprint ON entry(fingerprint, at);
                CREATE TABLE outcome (
                    id INTEGER PRIMARY KEY,
                    entry_id INTEGER NOT NULL REFERENCES entry(id) ON DELETE CASCADE,
                    item_id INTEGER NOT NULL,
                    position INTEGER NOT NULL,
                    outcome TEXT NOT NULL,
                    at REAL NOT NULL
                );
                CREATE INDEX outcome_entry ON outcome(entry_id);
                """)
        }
        try migrator.migrate(pool)
        try pool.write { db in
            try db.execute(
                sql: "UPDATE entry SET debug_context = NULL WHERE at < ?",
                arguments: [Date().addingTimeInterval(-14 * 86_400).timeIntervalSince1970]
            )
        }
    }

    @discardableResult
    public func log(_ entry: JournalEntry, at date: Date = Date()) throws -> Int64 {
        let suggestions = String(decoding: try JSONEncoder().encode(entry.suggestions), as: UTF8.self)
        return try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO entry (at, mode, bundle_id, fingerprint, dwell, suggestions, debug_context)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [date.timeIntervalSince1970, entry.mode.rawValue, entry.bundleID, entry.fingerprint,
                            entry.dwellSeconds, suggestions, entry.debugContext]
            )
            return db.lastInsertedRowID
        }
    }

    public func record(_ outcome: Outcome, entryID: Int64, itemID: Int64, position: Int, at date: Date = Date()) throws {
        try pool.write { db in
            try db.execute(
                sql: "INSERT INTO outcome (entry_id, item_id, position, outcome, at) VALUES (?, ?, ?, ?, ?)",
                arguments: [entryID, itemID, position, outcome.rawValue, date.timeIntervalSince1970]
            )
        }
    }

    public func deleteAll() throws {
        try pool.write { db in try db.execute(sql: "DELETE FROM outcome; DELETE FROM entry;") }
    }

    public func stats(days: Int, now: Date = Date()) throws -> JournalStats {
        try pool.read { db in
            let since = now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
            var stats = JournalStats(days: days)
            struct Row_ { let id: Int64; let mode: String; let fingerprint: String; let at: Double; let items: [Int64] }
            var entries: [Row_] = []
            for row in try Row.fetchAll(db, sql: "SELECT id, mode, fingerprint, at, suggestions FROM entry WHERE at >= ?", arguments: [since]) {
                let shown = (try? JSONDecoder().decode([JournalEntry.Shown].self, from: Data((row["suggestions"] as String).utf8))) ?? []
                entries.append(Row_(id: row["id"], mode: row["mode"], fingerprint: row["fingerprint"], at: row["at"], items: shown.map(\.itemID)))
            }
            var outcomes: [Int64: [(item: Int64, position: Int, outcome: Outcome)]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT entry_id, item_id, position, outcome FROM outcome WHERE at >= ?", arguments: [since]) {
                guard let outcome = Outcome(rawValue: row["outcome"]) else { continue }
                outcomes[row["entry_id"], default: []].append((row["item_id"], row["position"], outcome))
                if outcome.isUseful { stats.useful += 1 }
                if outcome == .dismissed || outcome == .muted || outcome == .blocked { stats.dismissed += 1 }
                if outcome == .ignored { stats.ignored += 1 }
            }
            var pullsWithOutcome = 0, pullTop = 0, pullAny = 0
            var ambientWithOutcome = 0, ambientUseful = 0
            for entry in entries {
                let results = outcomes[entry.id] ?? []
                switch entry.mode {
                case "pull":
                    stats.pulls += 1
                    if !results.isEmpty {
                        pullsWithOutcome += 1
                        if results.contains(where: { $0.outcome.isUseful && $0.position == 0 }) { pullTop += 1 }
                        if results.contains(where: { $0.outcome.isUseful }) { pullAny += 1 }
                    }
                case "ambient":
                    stats.ambient += 1
                    if !results.isEmpty {
                        ambientWithOutcome += 1
                        if results.contains(where: { $0.outcome.isUseful }) { ambientUseful += 1 }
                    }
                default:
                    stats.shadow += 1
                }
            }
            if pullsWithOutcome > 0 {
                stats.pullPrecisionAt1 = Double(pullTop) / Double(pullsWithOutcome)
                stats.pullPrecisionAt3 = Double(pullAny) / Double(pullsWithOutcome)
            }
            if ambientWithOutcome > 0 { stats.ambientPrecision = Double(ambientUseful) / Double(ambientWithOutcome) }
            // Shadow: did a later pull in the same context open the shadow's first pick?
            var shadowJudged = 0, shadowRight = 0
            let pulls = entries.filter { $0.mode == "pull" }
            for shadow in entries where shadow.mode == "shadow" {
                guard let first = shadow.items.first else { continue }
                let later = pulls.filter { $0.fingerprint == shadow.fingerprint && $0.at >= shadow.at && $0.at - shadow.at < 3_600 }
                let used = later.flatMap { (outcomes[$0.id] ?? []).filter { $0.outcome.isUseful }.map(\.item) }
                guard !later.isEmpty, later.contains(where: { outcomes[$0.id] != nil }) else { continue }
                shadowJudged += 1
                if used.contains(first) { shadowRight += 1 }
            }
            if shadowJudged > 0 { stats.shadowPrecision = Double(shadowRight) / Double(shadowJudged) }
            return stats
        }
    }
}
