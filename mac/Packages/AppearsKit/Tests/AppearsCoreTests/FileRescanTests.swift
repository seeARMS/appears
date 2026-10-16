import CoreServices
import Foundation
import GRDB
import Testing
@testable import AppearsCore

@Suite struct FileRescanTests {
    @Test func directoryEventsKeepTheirScopeAndRecoveryStillRequestsAFullScan() {
        let scanner = FileScanner(settings: SourceSettings(excludes: ["/fixture/Private"]), home: "/fixture")
        let directoryFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed)
        let fileFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified)
        let changes = FileChanges(paths: ["/fixture/Documents/Imported", "/fixture/Downloads/Old", "/fixture/Library/Caches/Generated",
                                          "/fixture/Private/Hidden", "/fixture/Documents/quote.txt", "/fixture/Library/cache.txt"],
                                  flags: [directoryFlags, directoryFlags, directoryFlags, directoryFlags, fileFlags, fileFlags],
                                  acceptsDirectory: scanner.shouldWatchFolder)
        #expect(!changes.fullScan)
        #expect(changes.directories == ["/fixture/Documents/Imported", "/fixture/Downloads/Old"])
        #expect(changes.files == ["/fixture/Documents/quote.txt"])
        #expect(Indexer.minimalDirectories(["/fixture/Documents", "/fixture/Documents/Imported", "/fixture/Documents-other"]) ==
                ["/fixture/Documents", "/fixture/Documents-other"])
        var combined = changes
        for flag in [kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagRootChanged,
                     kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped] {
            let recovery = FileChanges(paths: ["/fixture"], flags: [FSEventStreamEventFlags(flag)], acceptsDirectory: scanner.shouldWatchFolder)
            #expect(recovery.fullScan)
            combined.merge(recovery)
        }
        #expect(combined.fullScan)
        #expect(combined.directories == changes.directories)
    }

    @Test func subtreeScansReconcileRenamesAndRemovalsWithoutTouchingSiblings() async throws {
        let folder = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: ".build/appears-subtree-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = folder.appending(path: "Home")
        let changed = home.appending(path: "Trip_%")
        let sibling = home.appending(path: "Trip_%-other")
        for directory in [changed, sibling] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let quote = changed.appending(path: "quote.txt")
        let unrelated = sibling.appending(path: "unrelated.txt")
        try "A made-up kitchen quote.".write(to: quote, atomically: true, encoding: .utf8)
        try "An unrelated synthetic document.".write(to: unrelated, atomically: true, encoding: .utf8)
        let store = try IndexStore(url: folder.appending(path: "index.sqlite"))
        let embedder = HashingEmbedder()
        let vectors = VectorIndex(dimension: embedder.dimension)
        let indexer = Indexer(store: store, vectors: vectors, embedder: embedder,
                              settings: SourceSettings(notes: false, messages: false, homeOverride: home.path))
        await indexer.setPoliteness(false)
        #expect(try await indexer.scanFiles() == 2)
        #expect(try await indexer.indexPending() == 2)
        let original = try #require(try store.item(path: unrelated.path))
        let unit = try #require(try store.units(itemID: original.id).first)
        try "This edit should not be read by a scan of its sibling.".write(to: unrelated, atomically: true, encoding: .utf8)

        let renamed = home.appending(path: "Tríp_%")
        try FileManager.default.moveItem(at: changed, to: renamed)
        #expect(try await indexer.scanFiles(in: [changed.path, renamed.path, renamed.path + "/nested"]) == 1)
        #expect(try store.item(path: quote.path) == nil)
        #expect(try store.item(path: renamed.appending(path: "quote.txt").path) != nil)
        #expect(try store.item(path: unrelated.path) == original)
        #expect(try store.units(itemID: original.id).first?.unit == unit.unit)
        #expect(vectors.count == 1, "Only the removed file's vector is discarded")

        try FileManager.default.removeItem(at: renamed)
        #expect(try await indexer.scanFiles(in: [renamed.path]) == 0)
        #expect(try store.counts().items == 1)
        #expect(try store.item(path: unrelated.path) == original)
    }

    @Test func scopedWalksKeepExclusionsPackagesAndExplicitIncludes() throws {
        let folder = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: ".build/appears-scoped-skips-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let paths = ["Repository", "Library/Research", "Private", ".hidden", "Example.app/Contents"]
        for path in paths {
            let directory = folder.appending(path: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "A made-up quote.".write(to: directory.appending(path: "quote.txt"), atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: folder.appending(path: "Repository/.git"), withIntermediateDirectories: true)
        let included = folder.appending(path: "Library/Research")
        let scanner = FileScanner(settings: SourceSettings(includes: [included.path], excludes: [folder.appending(path: "Private").path]), home: folder.path)
        var found: [String] = []
        scanner.scan(in: paths.map { folder.appending(path: $0).path }) { found.append($0.path) }
        #expect(found == [included.appending(path: "quote.txt").path])
    }

    @Test func unchangedScansDoNotUpdateItemsOrDiscardUsageAndEmbeddings() async throws {
        let folder = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: ".build/appears-unchanged-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "quote.txt")
        try "A synthetic kitchen quote.".write(to: file, atomically: true, encoding: .utf8)
        let url = folder.appending(path: ".index/index.sqlite")
        let store = try IndexStore(url: url)
        let embedder = HashingEmbedder()
        let indexer = Indexer(store: store, vectors: VectorIndex(dimension: embedder.dimension), embedder: embedder,
                              settings: SourceSettings(notes: false, messages: false, homeOverride: folder.path))
        await indexer.setPoliteness(false)
        _ = try await indexer.scanFiles()
        _ = try await indexer.indexPending()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try store.touch(path: file.path, at: date)
        let original = try #require(try store.item(path: file.path))
        let unit = try #require(try store.units(itemID: original.id).first)
        let observer = try DatabaseQueue(path: url.path)
        try await observer.write { db in
            try db.execute(sql: """
                CREATE TABLE fixture_writes (n INTEGER NOT NULL);
                INSERT INTO fixture_writes VALUES (0);
                CREATE TRIGGER fixture_update AFTER UPDATE ON item BEGIN UPDATE fixture_writes SET n = n + 1; END;
                """)
        }
        #expect(try await indexer.scanFiles() == 1)
        let unchangedWrites = try await observer.read { try Int.fetchOne($0, sql: "SELECT n FROM fixture_writes") }
        #expect(unchangedWrites == 0)
        #expect(try store.item(path: file.path) == original)
        #expect(try store.units(itemID: original.id).first?.unit == unit.unit)
        #expect(try store.units(itemID: original.id).first?.vector == unit.vector)
        #expect(try store.counts().waiting == 0)
        try "An edited synthetic kitchen quote, with new cabinets.".write(to: file, atomically: true, encoding: .utf8)
        _ = try await indexer.scanFiles()
        let editedWrites = try await observer.read { try Int.fetchOne($0, sql: "SELECT n FROM fixture_writes") }
        #expect(editedWrites == 1)
        #expect(try store.counts().waiting == 1)
        #expect(try store.item(path: file.path)?.lastUsed == original.lastUsed)
    }
}
