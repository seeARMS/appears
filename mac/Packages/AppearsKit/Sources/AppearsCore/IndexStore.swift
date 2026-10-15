import Foundation
import GRDB

/// Appears' index, `index.sqlite`: one row per item you own (a file or a note), its units
/// (text chunks, PDF pages, images) with their vectors, and a full-text index over them.
///
/// It describes your own files, so it lives in the engine's container, is readable only by
/// you, and is excluded from backups. It never holds anything about what was on screen.
public final class IndexStore: Sendable {
    public let url: URL
    private let pool: DatabasePool

    public init(url: URL) throws {
        self.url = url
        let folder = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        }
        var config = Configuration()
        config.label = "index.sqlite"
        config.foreignKeysEnabled = true
        pool = try DatabasePool(path: url.path, configuration: config)
        try Self.migrator.migrate(pool)
        Self.protect(url)
    }

    // MARK: - Schema

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE item (
                    id INTEGER PRIMARY KEY,
                    source TEXT NOT NULL,
                    path TEXT NOT NULL UNIQUE,
                    kind TEXT NOT NULL,
                    title TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    created REAL NOT NULL,
                    modified REAL NOT NULL,
                    last_used REAL,
                    metadata_only INTEGER NOT NULL DEFAULT 0,
                    -- Size and modification date: a changed signature re-indexes the item.
                    signature TEXT NOT NULL,
                    -- 0: waiting, 1: indexed, 2: couldn't be read.
                    state INTEGER NOT NULL DEFAULT 0,
                    never_show INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX item_state ON item(state, kind);
                CREATE TABLE unit (
                    id INTEGER PRIMARY KEY,
                    item_id INTEGER NOT NULL REFERENCES item(id) ON DELETE CASCADE,
                    kind INTEGER NOT NULL,
                    locator TEXT NOT NULL,
                    text TEXT NOT NULL,
                    vector BLOB NOT NULL
                );
                CREATE INDEX unit_item ON unit(item_id);
                CREATE VIRTUAL TABLE unit_fts USING fts5(
                    title, text, tokenize='porter unicode61 remove_diacritics 2'
                );
                CREATE VIRTUAL TABLE unit_vocab USING fts5vocab(unit_fts, row);
                CREATE TRIGGER unit_ad AFTER DELETE ON unit BEGIN
                    DELETE FROM unit_fts WHERE rowid = old.id;
                END;
                """)
        }
        return migrator
    }

    /// Owner-only permissions, and no backups: the index can always be rebuilt.
    private static func protect(_ url: URL) {
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        for suffix in ["", "-wal", "-shm"] {
            var file = URL(filePath: url.path + suffix)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try? file.setResourceValues(excluded)
        }
    }

    // MARK: - Meta

    public func meta(_ key: String) throws -> String? {
        try pool.read { db in try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key]) }
    }

    public func setMeta(_ key: String, _ value: String) throws {
        try pool.write { db in
            try db.execute(
                sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [key, value]
            )
        }
    }

    /// Deletes every item and unit, for a model change or "Delete index".
    public func removeAll() throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM unit; DELETE FROM item; DELETE FROM unit_fts;")
        }
    }

    // MARK: - Items

    /// Records an item found by a scan. Returns its id and whether its content needs
    /// (re-)indexing: it's new, it changed, or it hasn't been indexed yet.
    @discardableResult
    public func record(_ item: Item, signature: String) throws -> (id: Int64, needsIndexing: Bool) {
        try pool.write { db in
            if let row = try Row.fetchOne(
                db, sql: "SELECT id, signature, state FROM item WHERE path = ?", arguments: [item.path]
            ) {
                let id: Int64 = row["id"]
                let unchanged = (row["signature"] as String) == signature
                // Spotlight's last-used date can move without the file changing.
                try db.execute(
                    sql: """
                        UPDATE item SET title = ?, kind = ?, size = ?, created = ?, modified = ?,
                            last_used = MAX(COALESCE(last_used, 0), COALESCE(?, 0)), metadata_only = ?,
                            signature = ?, state = CASE WHEN ? THEN state ELSE 0 END
                        WHERE id = ?
                        """,
                    arguments: [
                        item.title, item.kind.rawValue, item.size, item.created.timeIntervalSince1970,
                        item.modified.timeIntervalSince1970, item.lastUsed?.timeIntervalSince1970,
                        item.metadataOnly, signature, unchanged, id,
                    ]
                )
                return (id, !unchanged || (row["state"] as Int) == 0)
            }
            try db.execute(
                sql: """
                    INSERT INTO item (source, path, kind, title, size, created, modified, last_used,
                                      metadata_only, signature)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    item.source.rawValue, item.path, item.kind.rawValue, item.title, item.size,
                    item.created.timeIntervalSince1970, item.modified.timeIntervalSince1970,
                    item.lastUsed?.timeIntervalSince1970, item.metadataOnly, signature,
                ]
            )
            return (db.lastInsertedRowID, true)
        }
    }

    /// Items waiting for their content to be indexed, in the order the indexer should take
    /// them: documents, PDFs and notes before images, newest first within each.
    public func pending(limit: Int) throws -> [Item] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM item WHERE state = 0
                ORDER BY CASE kind WHEN 'image' THEN 1 ELSE 0 END, modified DESC
                LIMIT ?
                """, arguments: [limit]).map(Self.item)
        }
    }

    public func items(ids: [Int64]) throws -> [Int64: Item] {
        guard !ids.isEmpty else { return [:] }
        return try pool.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT * FROM item WHERE id IN (\(ids.map(String.init).joined(separator: ",")))"
            )
            return Dictionary(uniqueKeysWithValues: rows.map { (($0["id"] as Int64), Self.item($0)) })
        }
    }

    public func item(path: String) throws -> Item? {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM item WHERE path = ?", arguments: [path]).map(Self.item)
        }
    }

    /// Every item path from one source, with its id, for finding deleted files after a scan.
    public func paths(source: ItemSource) throws -> [String: Int64] {
        try pool.read { db in
            var paths: [String: Int64] = [:]
            let rows = try Row.fetchCursor(db, sql: "SELECT id, path FROM item WHERE source = ?", arguments: [source.rawValue])
            while let row = try rows.next() { paths[row["path"]] = row["id"] }
            return paths
        }
    }

    /// Removes items and their units. Returns the removed units' ids, for the vector index.
    @discardableResult
    public func remove(itemIDs: [Int64]) throws -> [Int64] {
        guard !itemIDs.isEmpty else { return [] }
        return try pool.write { db in
            var unitIDs: [Int64] = []
            for batch in itemIDs.chunked(500) {
                let list = batch.map(String.init).joined(separator: ",")
                unitIDs += try Int64.fetchAll(db, sql: "SELECT id FROM unit WHERE item_id IN (\(list))")
                try db.execute(sql: "DELETE FROM item WHERE id IN (\(list))")
            }
            return unitIDs
        }
    }

    /// Items whose path is under one of `prefixes` (for applying a new exclusion).
    public func itemIDs(under prefixes: [String]) throws -> [Int64] {
        guard !prefixes.isEmpty else { return [] }
        return try pool.read { db in
            var ids: [Int64] = []
            for prefix in prefixes {
                let folder = prefix.hasSuffix("/") ? prefix : prefix + "/"
                ids += try Int64.fetchAll(
                    db, sql: "SELECT id FROM item WHERE substr(path, 1, ?) = ?",
                    arguments: [folder.count, folder]
                )
            }
            return ids
        }
    }

    public func itemIDs(source: ItemSource) throws -> [Int64] {
        try pool.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM item WHERE source = ?", arguments: [source.rawValue])
        }
    }

    public func markFailed(itemID: Int64) throws {
        try pool.write { db in try db.execute(sql: "UPDATE item SET state = 2 WHERE id = ?", arguments: [itemID]) }
    }

    /// Records that a file was open on screen just now, which makes it "recently used".
    public func touch(path: String, at date: Date = Date()) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE item SET last_used = MAX(COALESCE(last_used, 0), ?) WHERE path = ?",
                arguments: [date.timeIntervalSince1970, path]
            )
        }
    }

    public func setNeverShow(itemID: Int64, _ value: Bool = true) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE item SET never_show = ? WHERE id = ?", arguments: [value, itemID])
        }
    }

    public func neverShown() throws -> Set<Int64> {
        try pool.read { db in Set(try Int64.fetchAll(db, sql: "SELECT id FROM item WHERE never_show = 1")) }
    }

    // MARK: - Units

    /// Replaces an item's units and marks it indexed. Returns the new units with their ids
    /// and the ids of the units they replaced.
    public func replaceUnits(
        itemID: Int64, title: String, units: [(unit: Unit, vector: [Float])]
    ) throws -> (added: [Unit], removed: [Int64]) {
        try pool.write { db in
            let removed = try Int64.fetchAll(db, sql: "SELECT id FROM unit WHERE item_id = ?", arguments: [itemID])
            try db.execute(sql: "DELETE FROM unit WHERE item_id = ?", arguments: [itemID])
            var added: [Unit] = []
            for (unit, vector) in units {
                try db.execute(
                    sql: "INSERT INTO unit (item_id, kind, locator, text, vector) VALUES (?, ?, ?, ?, ?)",
                    arguments: [itemID, unit.kind.rawValue, unit.locator.encoded, unit.text, Self.blob(vector)]
                )
                let id = db.lastInsertedRowID
                try db.execute(
                    sql: "INSERT INTO unit_fts (rowid, title, text) VALUES (?, ?, ?)",
                    arguments: [id, title, unit.text]
                )
                var stored = unit
                stored.id = id
                stored.itemID = itemID
                added.append(stored)
            }
            try db.execute(sql: "UPDATE item SET state = 1 WHERE id = ?", arguments: [itemID])
            return (added, removed)
        }
    }

    public func units(ids: [Int64]) throws -> [Int64: Unit] {
        guard !ids.isEmpty else { return [:] }
        return try pool.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT id, item_id, kind, locator, text FROM unit WHERE id IN (\(ids.map(String.init).joined(separator: ",")))"
            )
            return Dictionary(uniqueKeysWithValues: rows.map { (($0["id"] as Int64), Self.unit($0)) })
        }
    }

    /// Loads every stored vector into `index`.
    public func loadVectors(into index: VectorIndex) throws {
        try pool.read { db in
            let rows = try Row.fetchCursor(db, sql: "SELECT id, kind, vector FROM unit")
            while let row = try rows.next() {
                let data: Data = row["vector"]
                let halves = data.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
                guard halves.count == index.dimension else { continue }
                index.upsert(id: row["id"], kind: UnitKind(rawValue: row["kind"]) ?? .text, halves: halves)
            }
        }
    }

    /// The vector stored for a unit, for diversity between results.
    public func vectors(unitIDs: [Int64]) throws -> [Int64: [Float]] {
        guard !unitIDs.isEmpty else { return [:] }
        return try pool.read { db in
            var vectors: [Int64: [Float]] = [:]
            let rows = try Row.fetchAll(
                db, sql: "SELECT id, vector FROM unit WHERE id IN (\(unitIDs.map(String.init).joined(separator: ",")))"
            )
            for row in rows {
                let data: Data = row["vector"]
                vectors[row["id"]] = data.withUnsafeBytes { $0.bindMemory(to: Float16.self).map(Float.init) }
            }
            return vectors
        }
    }

    // MARK: - Full text

    public struct TextHit: Sendable, Hashable {
        public let unitID: Int64
        /// SQLite's bm25(), negated so higher is better.
        public let score: Double
    }

    /// Units matching an FTS5 query, best first.
    public func fullText(_ query: String, limit: Int) throws -> [TextHit] {
        guard !query.isEmpty else { return [] }
        return try pool.read { db in
            // Title matches count double: a file named after the person is a strong hit.
            try Row.fetchAll(db, sql: """
                SELECT rowid, bm25(unit_fts, 2.0, 1.0) AS rank FROM unit_fts WHERE unit_fts MATCH ?
                ORDER BY rank LIMIT ?
                """, arguments: [query, limit])
                .map { TextHit(unitID: $0["rowid"], score: -($0["rank"] as Double)) }
        }
    }

    /// In how many units each term appears, for picking a context's rarest words.
    public func documentFrequencies(_ terms: [String]) throws -> (counts: [String: Int], total: Int) {
        try pool.read { db in
            let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM unit") ?? 0
            guard !terms.isEmpty else { return ([:], total) }
            var counts: [String: Int] = [:]
            for batch in terms.chunked(400) {
                let marks = Array(repeating: "?", count: batch.count).joined(separator: ",")
                let rows = try Row.fetchAll(
                    db, sql: "SELECT term, doc FROM unit_vocab WHERE term IN (\(marks))",
                    arguments: StatementArguments(batch)
                )
                for row in rows { counts[row["term"]] = row["doc"] }
            }
            return (counts, total)
        }
    }

    // MARK: - Counts

    public func counts() throws -> IndexCounts {
        try pool.read { db in
            var counts = IndexCounts()
            for row in try Row.fetchAll(db, sql: "SELECT kind, state, count(*) AS n FROM item GROUP BY kind, state") {
                let n: Int = row["n"]
                let state: Int = row["state"]
                counts.items += n
                if state == 0 { counts.waiting += n }
                if state == 2 { counts.unreadable += n }
                if state == 1, let kind = ItemKind(rawValue: row["kind"]) { counts.indexed[kind, default: 0] += n }
            }
            counts.units = try Int.fetchOne(db, sql: "SELECT count(*) FROM unit") ?? 0
            return counts
        }
    }

    // MARK: - Rows

    private static func item(_ row: Row) -> Item {
        Item(
            id: row["id"],
            source: ItemSource(rawValue: row["source"]) ?? .file,
            path: row["path"],
            kind: ItemKind(rawValue: row["kind"]) ?? .document,
            title: row["title"],
            size: row["size"],
            created: Date(timeIntervalSince1970: row["created"]),
            modified: Date(timeIntervalSince1970: row["modified"]),
            lastUsed: (row["last_used"] as Double?).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil },
            metadataOnly: row["metadata_only"]
        )
    }

    private static func unit(_ row: Row) -> Unit {
        Unit(
            id: row["id"], itemID: row["item_id"], kind: UnitKind(rawValue: row["kind"]) ?? .text,
            locator: Locator(encoded: row["locator"]), text: row["text"]
        )
    }

    static func blob(_ vector: [Float]) -> Data {
        vector.map { Float16($0) }.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

public struct IndexCounts: Sendable, Codable, Equatable {
    public var items = 0
    public var waiting = 0
    public var unreadable = 0
    public var units = 0
    public var indexed: [ItemKind: Int] = [:]

    public init() {}

    public var indexedTotal: Int { indexed.values.reduce(0, +) }
}

extension Array {
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}
