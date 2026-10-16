import Foundation
import GRDB
import Testing

@testable import AppearsCore

@Suite struct IndexStoreTests {
    @Test func upgradesPendingOrderWithoutRebuildingStoredContent() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "appears-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "index.sqlite")
        let store = try IndexStore(url: url)
        func record(_ name: String, kind: ItemKind, modified: TimeInterval) throws -> Int64 {
            let item = Item(source: .file, path: folder.appending(path: name).path, kind: kind,
                            title: name, size: 1, created: Date(timeIntervalSince1970: 0),
                            modified: Date(timeIntervalSince1970: modified), lastUsed: nil)
            return try store.record(item, signature: name).id
        }
        let completed = try record("completed.txt", kind: .document, modified: 500)
        let vector = [Float](repeating: 0.25, count: 256)
        _ = try store.replaceUnits(itemID: completed, title: "completed.txt",
                                   units: [(Unit(kind: .text, locator: .whole, text: "Made-up kitchen quote."), vector)])
        try store.setMeta("model_id", "queue-test")
        let image = try record("quote.png", kind: .image, modified: 400)
        let older = try record("older.txt", kind: .document, modified: 100)
        let newer = try record("newer.pdf", kind: .pdf, modified: 200)
        let failed = try record("unreadable.txt", kind: .document, modified: 600)
        try store.markFailed(itemID: failed)

        // Recreate the previous schema, then let a fresh store migrate the existing index.
        let database = try DatabaseQueue(path: url.path)
        try database.write { db in
            try db.execute(sql: "DROP INDEX item_pending")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v4-pending-order'")
        }
        try database.close()
        let reopened = try IndexStore(url: url)
        #expect(try reopened.meta("model_id") == "queue-test")
        let saved = try #require(try reopened.units(itemID: completed).first)
        #expect(saved.unit.text == "Made-up kitchen quote.")
        #expect(saved.vector == vector)
        #expect(try reopened.pending(limit: 2).map(\.id) == [newer, older])
        #expect(try reopened.pending(limit: 16).map(\.id) == [newer, older, image])
        let migratedDatabase = try DatabaseQueue(path: url.path)
        let plan = try migratedDatabase.read { db in
            try Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN SELECT * FROM item WHERE state = 0
                ORDER BY CASE kind WHEN 'image' THEN 1 ELSE 0 END, modified DESC LIMIT 16
                """).map { $0["detail"] as String }
        }
        #expect(plan.contains { $0.contains("item_pending") }, "\(plan)")
        #expect(!plan.contains { $0.contains("TEMP B-TREE") }, "\(plan)")
    }
}
