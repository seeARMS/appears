import Foundation
import Testing
@testable import AppearsCore

@Suite struct SourceHealthTests {
    @Test func sourceCountsAndSuccessfulCheckDatesSurviveReopening() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "appears-health-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = folder.appending(path: "index.sqlite")
        let store = try IndexStore(url: database)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for (source, state) in [(ItemSource.file, 1), (.notes, 0), (.messages, 2)] {
            let item = Item(source: source, path: "\(source.rawValue):fixture", kind: .document, title: "Synthetic fixture",
                            size: 1, created: date, modified: date, lastUsed: nil)
            let (id, _) = try store.record(item, signature: "fixture")
            if state == 1 {
                _ = try store.replaceUnits(itemID: id, title: item.title,
                                           units: [(Unit(kind: .text, locator: .whole, text: "Made-up passage"), [1, 0, 0])])
            } else if state == 2 { try store.markFailed(itemID: id) }
        }
        try store.didCheck(.file, at: date)
        let reopened = try IndexStore(url: database)
        let statuses = try reopened.sourceStatuses()
        #expect(statuses.first { $0.source == .file } == SourceStatus(source: .file, indexed: 1, lastChecked: date))
        #expect(statuses.first { $0.source == .notes } == SourceStatus(source: .notes, waiting: 1))
        #expect(statuses.first { $0.source == .messages } == SourceStatus(source: .messages, unreadable: 1))
    }

    @Test func directoryEventsRespectSkipRulesAndExplicitIncludes() {
        let scanner = FileScanner(settings: SourceSettings(includes: ["/fixture/Library/Research"], excludes: ["/fixture/Private"]), home: "/fixture")
        #expect(scanner.shouldWatchFolder("/fixture/Documents/Imported"))
        #expect(scanner.shouldWatchFolder("/fixture/Library/Research/Imported"))
        #expect(!scanner.shouldWatchFolder("/fixture/Library/Caches"))
        #expect(!scanner.shouldWatchFolder("/fixture/.hidden"))
        #expect(!scanner.shouldWatchFolder("/fixture/Private/Imported"))
        #expect(!scanner.shouldWatchFolder("/outside"))
    }

    @Test(.timeLimit(.minutes(1))) func addedFolderWatchesCreatesEditsDeletesAndStopsWhenRemoved() async throws {
        // A regular directory exercises the same FSEvents path as an added user folder.
        let base = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: ".build/appears-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let folder = base.resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = folder.appending(path: "Home")
        let included = folder.appending(path: "Included")
        for path in [home, included] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        let settings = SourceSettings(notes: false, messages: false, homeOverride: home.path)
        let engine = try Engine(folder: folder.appending(path: "Engine"), embedder: HashingEmbedder(), settings: settings)
        await engine.indexer.setPoliteness(false)
        var updated = settings
        updated.includes = [included.path]
        _ = try await engine.handle(.settings, payload: JSONEncoder().encode(updated))
        #expect(await engine.status().watchedFolders.contains(included.path))
        let path = included.appending(path: "quote.txt")
        try "A made-up kitchen quote from Dana.".write(to: path, atomically: true, encoding: .utf8)
        try await waitUntil("create or edit") { try engine.store.item(path: path.path).flatMap { try engine.store.units(itemID: $0.id).first?.unit.text }?.contains("kitchen") == true }
        try "An updated made-up quote with new cabinets and an outlet.".write(to: path, atomically: true, encoding: .utf8)
        try await waitUntil("create or edit") { try engine.store.item(path: path.path).flatMap { try engine.store.units(itemID: $0.id).first?.unit.text }?.contains("outlet") == true }
        try FileManager.default.removeItem(at: path)
        try await waitUntil("delete") { try engine.store.item(path: path.path) == nil }
        let imported = included.appending(path: "Imported")
        try FileManager.default.createDirectory(at: imported, withIntermediateDirectories: true)
        let nested = imported.appending(path: "permit.txt")
        try "A synthetic permit for the kitchen.".write(to: nested, atomically: true, encoding: .utf8)
        try await waitUntil("directory import") { try engine.store.item(path: nested.path) != nil }
        let renamed = included.appending(path: "Renamed")
        try FileManager.default.moveItem(at: imported, to: renamed)
        let moved = renamed.appending(path: "permit.txt")
        try await waitUntil("directory rename") { try engine.store.item(path: nested.path) == nil && engine.store.item(path: moved.path) != nil }
        try FileManager.default.removeItem(at: renamed)
        try await waitUntil("directory removal") { try engine.store.item(path: moved.path) == nil }
        _ = try await engine.handle(.settings, payload: JSONEncoder().encode(settings))
        #expect(await !engine.status().watchedFolders.contains(included.path))
        try "This folder is no longer included.".write(to: path, atomically: true, encoding: .utf8)
        try await engine.indexer.filesChanged([path.path])
        #expect(try engine.store.item(path: path.path) == nil)
        #expect(try engine.store.sourceStatuses().first { $0.source == .file }?.lastChecked != nil)
    }

    private func waitUntil(_ label: String = #function, _ predicate: () throws -> Bool) async throws {
        for _ in 0..<100 {
            if try predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("A live file update did not reach the index within ten seconds: \(label)")
    }
}
