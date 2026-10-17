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
        for flag in [kFSEventStreamEventFlagItemChangeOwner, kFSEventStreamEventFlagItemInodeMetaMod] {
            let permissionChange = FileChanges(paths: ["/fixture/Documents/Imported"],
                                              flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | flag)],
                                              acceptsDirectory: scanner.shouldWatchFolder)
            #expect(permissionChange.directories == ["/fixture/Documents/Imported"])
        }
        for flag in [kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped] {
            let recovery = FileChanges(paths: ["/fixture/Private"], flags: [FSEventStreamEventFlags(flag)], acceptsDirectory: scanner.shouldWatchFolder)
            #expect(recovery.fullScan, "Dropped events require recovery even when their reported path is excluded")
        }
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
        try scanner.scan(in: paths.map { folder.appending(path: $0).path }) { found.append($0.path) }
        #expect(found == [included.appending(path: "quote.txt").path])
    }

    @Test func unreadableDirectoriesDoNotDeleteExistingItemsOrEmbeddings() async throws {
        let folder = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: ".build/appears-unreadable-\(UUID().uuidString)")
        let home = folder.appending(path: "Home")
        let blocked = home.appending(path: "Imported")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let file = blocked.appending(path: "quote.txt")
        try "A synthetic kitchen quote.".write(to: file, atomically: true, encoding: .utf8)
        let store = try IndexStore(url: folder.appending(path: "index.sqlite"))
        let embedder = HashingEmbedder()
        let vectors = VectorIndex(dimension: embedder.dimension)
        let indexer = Indexer(store: store, vectors: vectors, embedder: embedder,
                              settings: SourceSettings(notes: false, messages: false, homeOverride: home.path))
        await indexer.setPoliteness(false)
        _ = try await indexer.scanFiles()
        _ = try await indexer.indexPending()
        let original = try #require(try store.item(path: file.path))
        let unit = try #require(try store.units(itemID: original.id).first)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        let sibling = home.appending(path: "Imported-other")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let readable = sibling.appending(path: "new.txt")
        try "A new synthetic permit in a readable sibling.".write(to: readable, atomically: true, encoding: .utf8)
        for directories: [String]? in [nil, [blocked.path]] {
            _ = try await indexer.scanFiles(in: directories)
            #expect(await indexer.fileScanIssues.map(\.path) == [blocked.path])
            #expect(await indexer.fileScanIssues.first?.permissionDenied == true)
            #expect(try store.item(path: file.path) == original)
            #expect(try store.units(itemID: original.id).first?.unit == unit.unit)
            #expect(try store.units(itemID: original.id).first?.vector == unit.vector)
            #expect(vectors.count == 1)
            #expect(try store.item(path: readable.path) != nil, "A denied subtree must not discard readable siblings")
        }
        try await indexer.filesChanged([file.path])
        #expect(try store.item(path: file.path) == original, "A denied file event is not a deletion")
        #expect(try store.units(itemID: original.id).first?.vector == unit.vector)
        try FileManager.default.removeItem(at: readable)
        _ = try await indexer.scanFiles()
        #expect(try store.item(path: readable.path) == nil, "Readable siblings still reconcile real deletions")
        #expect(try store.item(path: file.path) == original)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
        _ = try await indexer.scanFiles(in: [blocked.path])
        #expect(await indexer.fileScanIssues.isEmpty, "A successful retry clears only the recovered subtree's warnings")
        #expect(try store.item(path: file.path) == original)
        try FileManager.default.removeItem(at: file)
        _ = try await indexer.scanFiles(in: [blocked.path])
        #expect(try store.item(path: file.path) == nil)
        #expect(vectors.count == 0)
    }

    @Test func unreadableRootDoesNotPreventOtherRootsAndCallbackErrorsPropagate() throws {
        let folder = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: ".build/appears-roots-\(UUID().uuidString)")
        let blocked = folder.appending(path: "Home")
        let included = folder.appending(path: "Included")
        for directory in [blocked, included] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
            try? FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        let file = included.appending(path: "permit.txt")
        try "An invented permit.".write(to: file, atomically: true, encoding: .utf8)
        let scanner = FileScanner(settings: SourceSettings(includes: [included.path], homeOverride: blocked.path))
        var found: [String] = []
        let issues = try scanner.scan { found.append($0.path) }
        #expect(found == [file.path])
        #expect(issues.map(\.path) == [blocked.path])
        #expect(throws: CancellationError.self) { try scanner.scan { _ in throw CancellationError() } }
    }

    @Test func missingIncludedRootKeepsItsIndexUntilItReturnsOrIsRemovedFromSources() async throws {
        let folder = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: ".build/appears-offline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = folder.appending(path: "Home")
        let included = folder.appending(path: "Included")
        for directory in [home, included] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let file = included.appending(path: "permit.txt")
        try "A synthetic permit on an included drive.".write(to: file, atomically: true, encoding: .utf8)
        let store = try IndexStore(url: folder.appending(path: "index.sqlite"))
        let embedder = HashingEmbedder()
        let vectors = VectorIndex(dimension: embedder.dimension)
        var settings = SourceSettings(includes: [included.path], notes: false, messages: false, homeOverride: home.path)
        let indexer = Indexer(store: store, vectors: vectors, embedder: embedder, settings: settings)
        await indexer.setPoliteness(false)
        _ = try await indexer.scanFiles()
        _ = try await indexer.indexPending()
        let original = try #require(try store.item(path: file.path))
        let offline = folder.appending(path: "Offline")
        try FileManager.default.moveItem(at: included, to: offline)
        for directories: [String]? in [nil, [included.path]] {
            _ = try await indexer.scanFiles(in: directories)
            #expect(try store.item(path: file.path) == original)
            #expect(vectors.count == 1)
            #expect(await indexer.fileScanIssues.map(\.path) == [included.path])
            #expect(await indexer.fileScanIssues.first?.permissionDenied == false)
        }
        try FileManager.default.moveItem(at: offline, to: included)
        _ = try await indexer.scanFiles(in: [included.path])
        #expect(await indexer.fileScanIssues.isEmpty)
        #expect(try store.item(path: file.path) == original)
        settings.includes = []
        try await indexer.update(settings: settings)
        _ = try await indexer.scanFiles()
        #expect(try store.item(path: file.path) == nil)
        #expect(vectors.count == 0)
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
