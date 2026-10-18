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
    private let hasStatusCounts: Bool
    /// Turns words into the terms the full-text index stores, with its own tokenizer.
    private let stemmer: DatabaseQueue

    /// `readOnly` opens an index another process owns (the engine), for `appears mcp`: no
    /// folder, no migration, no permission changes, and every write throws. WAL lets it read
    /// alongside the engine's writes.
    public init(url: URL, readOnly: Bool = false) throws {
        self.url = url
        // In memory, so a read-only index stems queries too.
        stemmer = try DatabaseQueue()
        try stemmer.write { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE stem USING fts5(word, tokenize='\(Self.tokenizer)');
                CREATE VIRTUAL TABLE stem_terms USING fts5vocab(stem, instance);
                """)
        }
        if readOnly {
            // A read-only connection can't create the WAL and shared-memory files, and can't
            // open a WAL database without them. macOS's SQLite keeps both after closing, so
            // they're missing only from a copied index; empty ones are what SQLite would make.
            if FileManager.default.fileExists(atPath: url.path) {
                for suffix in ["-wal", "-shm"] where !FileManager.default.fileExists(atPath: url.path + suffix) {
                    FileManager.default.createFile(atPath: url.path + suffix, contents: nil, attributes: [.posixPermissions: 0o600])
                }
            }
            var config = Configuration()
            config.label = "index.sqlite (read-only)"
            config.readonly = true
            pool = try DatabasePool(path: url.path, configuration: config)
            hasStatusCounts = try pool.read { try $0.tableExists("item_count") && $0.tableExists("unit_count") }
            return
        }
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
        hasStatusCounts = true
        Self.protect(url)
    }

    // MARK: - Schema

    /// Porter stems, so "quoted" matches "quote".
    static let tokenizer = "porter unicode61 remove_diacritics 2"

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
                    title, text, tokenize='\(tokenizer)'
                );
                CREATE VIRTUAL TABLE unit_vocab USING fts5vocab(unit_fts, row);
                CREATE TRIGGER unit_ad AFTER DELETE ON unit BEGIN
                    DELETE FROM unit_fts WHERE rowid = old.id;
                END;
                """)
        }
        // An image's OCR text was indexed twice when it was also a text unit.
        migrator.registerMigration("v2") { db in
            try db.execute(sql: """
                DELETE FROM unit_fts WHERE rowid IN (
                    SELECT image.id FROM unit image JOIN unit text
                        ON text.item_id = image.item_id AND text.locator = image.locator AND text.text = image.text
                    WHERE image.kind = 1 AND text.kind = 0
                )
                """)
        }
        migrator.registerMigration("v3-messages") { db in
            try db.execute(sql: "ALTER TABLE item ADD COLUMN message BLOB")
        }
        migrator.registerMigration("v4-pending-order") { db in
            // Match pending(limit:)'s order so each batch can read its first few rows
            // directly, instead of sorting a large Messages backlog again. Leading with
            // state lets SQLite choose this index without waiting for ANALYZE statistics.
            try db.execute(sql: """
                CREATE INDEX item_pending ON item (
                    state, (CASE kind WHEN 'image' THEN 1 ELSE 0 END), modified DESC
                ) WHERE state = 0
                """)
        }
        migrator.registerMigration("v5-status-counts") { db in
            // Status is polled while indexing. Maintain a few aggregate rows in the same
            // transaction as each change, instead of recounting the entire index per poll.
            try db.execute(sql: """
                CREATE INDEX item_source_path ON item(source, path);
                CREATE TABLE item_count (
                    source TEXT NOT NULL, kind TEXT NOT NULL, state INTEGER NOT NULL,
                    n INTEGER NOT NULL, PRIMARY KEY (source, kind, state)
                ) WITHOUT ROWID;
                INSERT INTO item_count SELECT source, kind, state, count(*) FROM item GROUP BY source, kind, state;
                CREATE TABLE unit_count (id INTEGER PRIMARY KEY CHECK (id = 1), n INTEGER NOT NULL);
                INSERT INTO unit_count SELECT 1, count(*) FROM unit;
                CREATE TRIGGER item_count_ai AFTER INSERT ON item BEGIN
                    INSERT INTO item_count VALUES (new.source, new.kind, new.state, 1)
                    ON CONFLICT(source, kind, state) DO UPDATE SET n = n + 1;
                END;
                CREATE TRIGGER item_count_ad AFTER DELETE ON item BEGIN
                    UPDATE item_count SET n = n - 1
                    WHERE source = old.source AND kind = old.kind AND state = old.state;
                END;
                CREATE TRIGGER item_count_au AFTER UPDATE OF source, kind, state ON item
                WHEN old.source != new.source OR old.kind != new.kind OR old.state != new.state BEGIN
                    UPDATE item_count SET n = n - 1
                    WHERE source = old.source AND kind = old.kind AND state = old.state;
                    INSERT INTO item_count VALUES (new.source, new.kind, new.state, 1)
                    ON CONFLICT(source, kind, state) DO UPDATE SET n = n + 1;
                END;
                CREATE TRIGGER unit_count_ai AFTER INSERT ON unit BEGIN
                    UPDATE unit_count SET n = n + 1 WHERE id = 1;
                END;
                CREATE TRIGGER unit_count_ad AFTER DELETE ON unit BEGIN
                    UPDATE unit_count SET n = n - 1 WHERE id = 1;
                END;
                """)
        }
        migrator.registerMigration("v6-message-retrieval") { db in
            try db.execute(sql: """
                CREATE INDEX item_message_chat_date ON item (
                    json_extract(CAST(message AS TEXT), '$.chatID'), modified
                ) WHERE source = 'messages';
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
                            message = ?, signature = ?, state = CASE WHEN ? THEN state ELSE 0 END
                        WHERE id = ?
                        """,
                    arguments: [
                        item.title, item.kind.rawValue, item.size, item.created.timeIntervalSince1970,
                        item.modified.timeIntervalSince1970, item.lastUsed?.timeIntervalSince1970,
                        item.metadataOnly, try item.message.map { try JSONEncoder().encode($0) }, signature, unchanged, id,
                    ]
                )
                return (id, !unchanged || (row["state"] as Int) == 0)
            }
            try db.execute(
                sql: """
                    INSERT INTO item (source, path, kind, title, size, created, modified, last_used,
                                      metadata_only, signature, message)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    item.source.rawValue, item.path, item.kind.rawValue, item.title, item.size,
                    item.created.timeIntervalSince1970, item.modified.timeIntervalSince1970,
                    item.lastUsed?.timeIntervalSince1970, item.metadataOnly, signature, try item.message.map { try JSONEncoder().encode($0) },
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

    /// Capture the current content version, rather than a possibly stale pending batch.
    func indexingRecord(itemID: Int64) throws -> (item: Item, signature: String)? {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM item WHERE id = ? AND state = 0", arguments: [itemID])
                .map { (Self.item($0), $0["signature"]) }
        }
    }

    func pendingSignature(itemID: Int64) throws -> String? {
        try pool.read { db in
            try String.fetchOne(db, sql: "SELECT signature FROM item WHERE id = ? AND state = 0", arguments: [itemID])
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

    /// Only the files a walk can reconcile. A subtree removal must not remove siblings
    /// or another source. Binary prefix ranges use item_source_path, including Unicode paths.
    func fileRecords(in directories: [String]?) throws -> [String: (item: Item, signature: String)] {
        try pool.read { db in
            var result: [String: (item: Item, signature: String)] = [:]
            func read(_ sql: String, arguments: StatementArguments = []) throws {
                let rows = try Row.fetchCursor(db, sql: sql, arguments: arguments)
                while let row = try rows.next() {
                    let item = Self.item(row)
                    result[item.path] = (item, row["signature"])
                }
            }
            if let directories {
                for directory in directories {
                    let prefix = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
                    try read("SELECT * FROM item WHERE source = 'file' AND path >= ? AND path < ?",
                             arguments: [prefix + "/", prefix + "0"])
                }
            } else {
                try read("SELECT * FROM item WHERE source = 'file'")
            }
            return result
        }
    }

    /// Skip unchanged Messages entries without opening a write transaction for every message.
    func sourceRecords(_ source: ItemSource) throws -> [String: (id: Int64, signature: String)] {
        try pool.read { db in
            var result: [String: (id: Int64, signature: String)] = [:]
            let rows = try Row.fetchCursor(db, sql: "SELECT id, path, signature FROM item WHERE source = ?", arguments: [source.rawValue])
            while let row = try rows.next() { result[row["path"]] = (row["id"], row["signature"]) }
            return result
        }
    }

    func messageRecords(rowID: Int64) throws -> [String: (id: Int64, signature: String)] {
        try pool.read { db in
            var result: [String: (id: Int64, signature: String)] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, path, signature FROM item WHERE source = 'messages' AND (path = ? OR path GLOB ?)",
                                        arguments: [MessagesReader.path(rowID), MessagesReader.path(rowID) + ":photo:*"]) {
                result[row["path"]] = (row["id"], row["signature"])
            }
            return result
        }
    }

    func markMessagesPending(rowIDs: [Int64]) throws {
        try pool.write { db in
            for rowID in Set(rowIDs) {
                try db.execute(sql: "UPDATE item SET state = 0 WHERE source = 'messages' AND (path = ? OR path GLOB ?)",
                               arguments: [MessagesReader.path(rowID), MessagesReader.path(rowID) + ":photo:*"])
            }
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

    public func itemIDs(kinds: Set<ItemKind>) throws -> [Int64] {
        guard !kinds.isEmpty else { return [] }
        return try pool.read { db in
            let marks = Array(repeating: "?", count: kinds.count).joined(separator: ",")
            return try Int64.fetchAll(
                db, sql: "SELECT id FROM item WHERE kind IN (\(marks))", arguments: StatementArguments(kinds.map(\.rawValue))
            )
        }
    }

    public func markFailed(itemID: Int64, signature: String? = nil) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE item SET state = 2 WHERE id = ? AND (? IS NULL OR signature = ?)",
                           arguments: [itemID, signature, signature])
        }
    }

    /// An explicit retry also retries extraction failures whose file signature hasn't changed.
    public func retryFailed() throws {
        try pool.write { db in try db.execute(sql: "UPDATE item SET state = 0 WHERE state = 2") }
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
        itemID: Int64, title: String, units: [(unit: Unit, vector: [Float])], signature: String? = nil
    ) throws -> (added: [Unit], removed: [Int64]) {
        try pool.write { db in
            if let signature {
                guard try String.fetchOne(db, sql: "SELECT signature FROM item WHERE id = ? AND state = 0", arguments: [itemID]) == signature
                else { return ([], []) }
            }
            let removed = try Int64.fetchAll(db, sql: "SELECT id FROM unit WHERE item_id = ?", arguments: [itemID])
            try db.execute(sql: "DELETE FROM unit WHERE item_id = ?", arguments: [itemID])
            var added: [Unit] = []
            // A screenshot's or scanned page's OCR text is often also a text unit. Its words go
            // in the full-text index once, under the text unit, or they'd look twice as common.
            let texts = Set(units.filter { $0.unit.kind == .text }.map { [$0.unit.locator.encoded, $0.unit.text] })
            for (unit, vector) in units {
                try db.execute(
                    sql: "INSERT INTO unit (item_id, kind, locator, text, vector) VALUES (?, ?, ?, ?, ?)",
                    arguments: [itemID, unit.kind.rawValue, unit.locator.encoded, unit.text, Self.blob(vector)]
                )
                let id = db.lastInsertedRowID
                if unit.kind == .text || !texts.contains([unit.locator.encoded, unit.text]) {
                    try db.execute(
                        sql: "INSERT INTO unit_fts (rowid, title, text) VALUES (?, ?, ?)",
                        arguments: [id, title, unit.text]
                    )
                }
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

    /// Validate previously retrieved units and their item versions/visibility in one
    /// WAL snapshot, including when a read-only client shares the engine's live index.
    func unchangedVisibleUnits(_ versions: [(item: Item, unit: Unit)]) throws -> Set<Int64> {
        guard !versions.isEmpty else { return [] }
        return try pool.read { db in
            let unitIDs = versions.map { String($0.unit.id) }.joined(separator: ",")
            let itemIDs = versions.map { String($0.item.id) }.joined(separator: ",")
            let unitRows = try Row.fetchAll(db, sql: "SELECT id, item_id, kind, locator, text FROM unit WHERE id IN (\(unitIDs))")
            let itemRows = try Row.fetchAll(db, sql: "SELECT * FROM item WHERE id IN (\(itemIDs)) AND never_show = 0 AND state = 1")
            let units = Dictionary(uniqueKeysWithValues: unitRows.map { (($0["id"] as Int64), Self.unit($0)) })
            let items = Dictionary(uniqueKeysWithValues: itemRows.map { (($0["id"] as Int64), Self.item($0)) })
            return Set(versions.compactMap { expected in
                guard units[expected.unit.id] == expected.unit, let current = items[expected.item.id],
                      current.path == expected.item.path, current.source == expected.item.source,
                      current.kind == expected.item.kind, current.title == expected.item.title,
                      current.created == expected.item.created, current.modified == expected.item.modified,
                      current.size == expected.item.size, current.message == expected.item.message,
                      current.metadataOnly == expected.item.metadataOnly else { return nil }
                return expected.unit.id
            })
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

    /// One item's units, in order, with their stored vectors.
    public func units(itemID: Int64) throws -> [(unit: Unit, vector: [Float])] {
        try pool.read { db in
            try Row.fetchAll(
                db, sql: "SELECT id, item_id, kind, locator, text, vector FROM unit WHERE item_id = ? ORDER BY id",
                arguments: [itemID]
            ).map { row in
                let data: Data = row["vector"]
                return (Self.unit(row), data.withUnsafeBytes { $0.bindMemory(to: Float16.self).map(Float.init) })
            }
        }
    }

    /// Changes whenever units are added or removed or an item is re-indexed, so a reader in
    /// another process (`appears mcp`) knows when its copy of the vectors is stale. Re-indexing
    /// can reuse the unit ids it deleted, so item dates and sizes count too.
    public func contentStamp() throws -> String {
        try pool.read { db in
            let units = try Row.fetchOne(db, sql: "SELECT count(*) AS n, coalesce(max(id), 0) AS last FROM unit")
            let items = try Row.fetchOne(
                db, sql: "SELECT count(*) AS n, total(modified) AS modified, total(size) AS size FROM item WHERE state = 1"
            )
            let unitCount: Int = units?["n"] ?? 0
            let lastUnit: Int64 = units?["last"] ?? 0
            let itemCount: Int = items?["n"] ?? 0
            let modified: Double = items?["modified"] ?? 0
            let size: Double = items?["size"] ?? 0
            return "\(unitCount)/\(lastUnit)/\(itemCount)/\(modified)/\(size)"
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

    /// Apply conversation scope before LIMIT so a busy global index cannot crowd
    /// out this conversation. Stable chat IDs are hints, never title-based exclusions.
    func messageHits(_ query: String, chatIDs: [Int64]?, limit: Int, newestFirst: Bool = false) throws -> [TextHit] {
        guard !query.isEmpty, chatIDs?.isEmpty != true else { return [] }
        return try pool.read { db in
            let marks = Array(repeating: "?", count: chatIDs?.count ?? 0).joined(separator: ",")
            let scope = chatIDs == nil ? "" : "AND json_extract(CAST(item.message AS TEXT), '$.chatID') IN (\(marks))"
            let ordering = newestFirst ? "item.created DESC, rank" : "rank"
            return try Row.fetchAll(db, sql: """
                SELECT unit_fts.rowid, bm25(unit_fts, 2.0, 1.0) AS rank
                FROM unit_fts JOIN unit ON unit.id = unit_fts.rowid JOIN item ON item.id = unit.item_id
                WHERE unit_fts MATCH ? AND item.source = 'messages' AND item.never_show = 0
                  \(scope)
                ORDER BY \(ordering) LIMIT ?
                """, arguments: StatementArguments([query] + (chatIDs ?? []).map { $0 as DatabaseValueConvertible } + [limit]))
                .map { TextHit(unitID: $0["rowid"], score: -($0["rank"] as Double)) }
        }
    }

    /// Bounded source windows for discussion expansion. Each unit is still independently
    /// scored and, when Messages is available, revalidated against the original message.
    func messageNeighbours(of item: Item, limit: Int = 40) throws -> [(Item, Unit)] {
        guard let chat = item.message?.chatID else { return [] }
        return try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT item.*, unit.id AS uid, unit.kind AS ukind, unit.locator, unit.text
                FROM item JOIN unit ON unit.item_id = item.id
                WHERE item.source = 'messages' AND item.kind = 'message' AND item.never_show = 0
                  AND json_extract(CAST(item.message AS TEXT), '$.chatID') = ?
                  AND item.modified BETWEEN ? AND ? AND unit.kind = 0
                ORDER BY abs(item.modified - ?) LIMIT ?
                """, arguments: [chat, item.modified.timeIntervalSince1970 - 86_400,
                                   item.modified.timeIntervalSince1970 + 86_400, item.modified.timeIntervalSince1970, limit])
            return rows.compactMap { row in
                let item = Self.item(row)
                let unit = Unit(id: row["uid"], itemID: item.id, kind: .text,
                                locator: Locator(encoded: row["locator"]), text: row["text"])
                return (item, unit)
            }
        }
    }

    /// In how many units each term appears, for picking a context's rarest words.
    /// Keyed by the words as given. They're stemmed the way the index stems them, so "quote"
    /// counts the units that say "quoted" (both are "quot").
    public func documentFrequencies(_ words: [String]) throws -> (counts: [String: Int], total: Int) {
        let words = Array(Set(words))
        let terms = try stems(words)
        return try pool.read { db in
            let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM unit") ?? 0
            guard !terms.isEmpty else { return ([:], total) }
            var byTerm: [String: Int] = [:]
            for batch in Array(Set(terms.values)).chunked(400) {
                let marks = Array(repeating: "?", count: batch.count).joined(separator: ",")
                let rows = try Row.fetchAll(
                    db, sql: "SELECT term, doc FROM unit_vocab WHERE term IN (\(marks))",
                    arguments: StatementArguments(batch)
                )
                for row in rows { byTerm[row["term"]] = row["doc"] }
            }
            return (terms.compactMapValues { byTerm[$0] }, total)
        }
    }

    /// Each word's first term, from the index's tokenizer.
    func stems(_ words: [String]) throws -> [String: String] {
        guard !words.isEmpty else { return [:] }
        return try stemmer.write { db in
            try db.execute(sql: "DELETE FROM stem")
            for (index, word) in words.enumerated() {
                try db.execute(sql: "INSERT INTO stem (rowid, word) VALUES (?, ?)", arguments: [index + 1, word])
            }
            var stems: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT term, doc FROM stem_terms WHERE offset = 0") {
                stems[words[(row["doc"] as Int) - 1]] = row["term"]
            }
            return stems
        }
    }

    // MARK: - Counts

    public func sourceStatuses() throws -> [SourceStatus] {
        try pool.read { db in
            try [ItemSource.file, .notes, .messages].map { source in
                let sql = hasStatusCounts
                    ? "SELECT state, sum(n) AS n FROM item_count WHERE source = ? GROUP BY state"
                    : "SELECT state, count(*) AS n FROM item WHERE source = ? GROUP BY state"
                let rows = try Row.fetchAll(db, sql: sql, arguments: [source.rawValue])
                var status = SourceStatus(source: source)
                for row in rows {
                    let count: Int = row["n"]
                    switch row["state"] as Int {
                    case 0: status.waiting += count
                    case 1: status.indexed += count
                    case 2: status.unreadable += count
                    default: break
                    }
                }
                let value = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: ["checked_\(source.rawValue)"])
                status.lastChecked = value.flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
                return status
            }
        }
    }

    func didCheck(_ source: ItemSource, at date: Date = Date()) throws {
        try setMeta("checked_\(source.rawValue)", String(date.timeIntervalSince1970))
    }

    public func counts() throws -> IndexCounts {
        try pool.read { db in
            var counts = IndexCounts()
            let sql = hasStatusCounts
                ? "SELECT kind, state, sum(n) AS n FROM item_count WHERE n > 0 GROUP BY kind, state"
                : "SELECT kind, state, count(*) AS n FROM item GROUP BY kind, state"
            for row in try Row.fetchAll(db, sql: sql) {
                let n: Int = row["n"]
                let state: Int = row["state"]
                counts.items += n
                if state == 0 { counts.waiting += n }
                if state == 2 { counts.unreadable += n }
                if state == 1, let kind = ItemKind(rawValue: row["kind"]) { counts.indexed[kind, default: 0] += n }
            }
            counts.units = try Int.fetchOne(db, sql: hasStatusCounts ? "SELECT n FROM unit_count WHERE id = 1" : "SELECT count(*) FROM unit") ?? 0
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
            metadataOnly: row["metadata_only"],
            message: (row.hasColumn("message") ? row["message"] as Data? : nil).flatMap { try? JSONDecoder().decode(MessageReference.self, from: $0) }
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
