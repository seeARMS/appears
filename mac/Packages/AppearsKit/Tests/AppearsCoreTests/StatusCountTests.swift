import Foundation
import GRDB
import Testing
@testable import AppearsCore

@Suite struct StatusCountTests {
    @Test func maintainedCountsFollowEveryIndexMutationAndCascade() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "appears-counts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "index.sqlite")
        let store = try IndexStore(url: url)
        let observer = try DatabaseQueue(path: url.path)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var file = Item(source: .file, path: "/fixture/quote.txt", kind: .document, title: "Made-up quote",
                        size: 20, created: date, modified: date, lastUsed: nil)
        let fileID = try store.record(file, signature: "original").id
        let message = Item(source: .messages, path: "messages:42", kind: .message, title: "Synthetic conversation",
                           size: 20, created: date, modified: date, lastUsed: nil)
        let messageID = try store.record(message, signature: "message").id
        let note = Item(source: .notes, path: "notes:fixture", kind: .note, title: "Synthetic note",
                        size: 20, created: date, modified: date, lastUsed: nil)
        let noteID = try store.record(note, signature: "note").id
        try assertCounts(store, observer)
        let units = [(Unit(kind: .text, locator: .whole, text: "Made-up kitchen quote."), [Float(1), 0, 0]),
                     (Unit(kind: .image, locator: .page(1), text: "Synthetic image text."), [Float(0), 1, 0])]
        _ = try store.replaceUnits(itemID: fileID, title: file.title, units: units)
        _ = try store.replaceUnits(itemID: messageID, title: message.title, units: Array(units.prefix(1)))
        try store.markFailed(itemID: noteID)
        try assertCounts(store, observer)

        // Replacement deletes old units before inserting new ones; edits requeue an item.
        _ = try store.replaceUnits(itemID: fileID, title: file.title, units: Array(units.prefix(1)))
        file.kind = .pdf
        file.modified = date.addingTimeInterval(1)
        _ = try store.record(file, signature: "edited")
        try store.markMessagesPending(rowIDs: [42])
        try assertCounts(store, observer)
        try store.touch(path: file.path, at: date)
        try store.setNeverShow(itemID: fileID)
        try store.markFailed(itemID: fileID)
        try store.markFailed(itemID: fileID) // Repeated state assignments must not change totals.
        try assertCounts(store, observer)
        try store.remove(itemIDs: [messageID, fileID])
        try assertCounts(store, observer)
        let reopened = try IndexStore(url: url, readOnly: true)
        #expect(try reopened.counts() == store.counts())
        #expect(try reopened.sourceStatuses() == store.sourceStatuses())
        try store.removeAll()
        try assertCounts(store, observer)
        #expect(try store.counts().items == 0)
        #expect(try store.counts().units == 0)
    }

    @Test func migrationBackfillsCountsAndPreservesEmbeddingsAndLegacyReaders() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "appears-count-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "index.sqlite")
        let store = try IndexStore(url: url)
        let item = Item(source: .file, path: "/fixture/quote.txt", kind: .document, title: "Synthetic quote",
                        size: 20, created: .distantPast, modified: .distantPast, lastUsed: nil)
        let id = try store.record(item, signature: "fixture").id
        let vector: [Float] = [1, 0, 0]
        _ = try store.replaceUnits(itemID: id, title: item.title,
                                   units: [(Unit(kind: .text, locator: .whole, text: "Made-up kitchen quote."), vector)])
        try store.setMeta("model_id", "synthetic-model")
        let saved = try #require(try store.units(itemID: id).first)
        let expectedCounts = try store.counts()
        let expectedSources = try store.sourceStatuses()
        let database = try DatabaseQueue(path: url.path)
        try database.write { db in
            try db.execute(sql: """
                DROP TRIGGER item_count_ai; DROP TRIGGER item_count_ad; DROP TRIGGER item_count_au;
                DROP TRIGGER unit_count_ai; DROP TRIGGER unit_count_ad;
                DROP TABLE item_count; DROP TABLE unit_count; DROP INDEX item_source_path;
                DELETE FROM grdb_migrations WHERE identifier = 'v5-status-counts';
                """)
        }
        // MCP can still read an index last opened by an older engine, without migrating it.
        let legacyReader = try IndexStore(url: url, readOnly: true)
        #expect(try legacyReader.counts() == expectedCounts)
        #expect(try legacyReader.sourceStatuses() == expectedSources)
        let migrated = try IndexStore(url: url)
        #expect(try migrated.meta("model_id") == "synthetic-model")
        #expect(try migrated.counts() == expectedCounts)
        #expect(try migrated.sourceStatuses() == expectedSources)
        #expect(try migrated.units(itemID: id).first?.unit == saved.unit)
        #expect(try migrated.units(itemID: id).first?.vector == saved.vector)
        try assertCounts(migrated, database)
        try migrated.markFailed(itemID: id)
        try assertCounts(migrated, database)
    }

    private func assertCounts(_ store: IndexStore, _ database: DatabaseQueue, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let counts = try store.counts()
        let statuses = try store.sourceStatuses()
        try database.read { (db: Database) throws -> Void in
            #expect(try counts.items == Int.fetchOne(db, sql: "SELECT count(*) FROM item"), sourceLocation: sourceLocation)
            #expect(try counts.units == Int.fetchOne(db, sql: "SELECT count(*) FROM unit"), sourceLocation: sourceLocation)
            #expect(try counts.waiting == Int.fetchOne(db, sql: "SELECT count(*) FROM item WHERE state = 0"), sourceLocation: sourceLocation)
            #expect(try counts.unreadable == Int.fetchOne(db, sql: "SELECT count(*) FROM item WHERE state = 2"), sourceLocation: sourceLocation)
            for kind in ItemKind.allCases {
                #expect(try counts.indexed[kind, default: 0] == Int.fetchOne(db, sql: "SELECT count(*) FROM item WHERE state = 1 AND kind = ?",
                                                                     arguments: [kind.rawValue]), sourceLocation: sourceLocation)
            }
            for status in statuses {
                for (state, count) in [(0, status.waiting), (1, status.indexed), (2, status.unreadable)] {
                    #expect(try count == Int.fetchOne(db, sql: "SELECT count(*) FROM item WHERE source = ? AND state = ?",
                                                 arguments: [status.source.rawValue, state]), sourceLocation: sourceLocation)
                }
            }
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM item_count WHERE n < 0") == 0, sourceLocation: sourceLocation)
        }
    }
}
