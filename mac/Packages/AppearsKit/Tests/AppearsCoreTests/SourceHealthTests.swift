import CoreServices
import Foundation
import Synchronization
import Testing
@testable import AppearsCore

@Suite struct SourceHealthTests {
    @Test func scopedFileUpdatesCannotClearAnUnresolvedFullScanFailure() async throws {
        let folder = URL(filePath: FileManager.default.currentDirectoryPath).appending(path: ".build/appears-scan-errors-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = folder.appending(path: "Home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let path = home.appending(path: "permit.txt")
        try "An invented kitchen permit.".write(to: path, atomically: true, encoding: .utf8)
        let fail = Mutex(true)
        let engine = try Engine(folder: folder.appending(path: "Engine"), embedder: HashingEmbedder(),
                                settings: SourceSettings(notes: false, messages: false, homeOverride: home.path), fileWalk: { scanner in
            if fail.withLock({ $0 }) { throw CocoaError(.fileReadNoPermission) }
            var items: [Item] = []
            try scanner.scan { items.append($0) }
            return items
        })
        await engine.indexer.setPoliteness(false)
        await engine.refresh()
        let failure = try #require(await engine.status().error)
        #expect(failure.contains("Couldn’t scan files"))
        var scopedFailure = FileChanges()
        scopedFailure.directories = [home.path]
        await engine.processFileChanges(scopedFailure)
        #expect(await engine.status().error == failure, "A watcher failure must not overwrite a full-scan failure")
        let changed = FileChanges(paths: [path.path], flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified)],
                                  acceptsDirectory: { _ in true })
        await engine.processFileChanges(changed)
        #expect(try engine.store.item(path: path.path) != nil)
        #expect(await engine.status().error == failure, "A successful file event must not clear a full-scan failure")
        fail.withLock { $0 = false }
        var recovery = FileChanges()
        recovery.fullScan = true
        await engine.processFileChanges(recovery)
        #expect(await engine.status().error == nil, "A full recovery scan clears both full-scan and watcher errors")
    }

    @Test(.timeLimit(.minutes(1))) func retryReportsRunningCompletionAndFailureAndCoalescesRequests() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "appears-retry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let walk = RetryWalk()
        defer { walk.finish.signal() }
        let engine = try Engine(folder: folder.appending(path: "Engine"), embedder: HashingEmbedder(),
                                settings: SourceSettings(notes: false, messages: false, homeOverride: folder.appending(path: "Home").path),
                                fileWalk: walk.walk)
        let item = Item(source: .file, path: folder.appending(path: "Home/retry.txt").path, kind: .document,
                        title: "Synthetic unreadable item", size: 1, created: .now, modified: .now, lastUsed: nil)
        let (id, _) = try engine.store.record(item, signature: "unchanged")
        try engine.store.markFailed(itemID: id)
        _ = try await engine.handle(.rescan, payload: Data("{}".utf8))
        await walk.waitUntilStarted()
        #expect(try engine.store.counts().waiting == 1, "Explicit retry requeues unchanged unreadable items")
        let running = await engine.status()
        #expect(running.isScanning)
        #expect(running.lastScanCompletedAt == nil)
        _ = try await engine.handle(.rescan, payload: Data("{}".utf8))
        #expect(walk.state.withLock { $0.count } == 1, "Repeated requests share the full source pass")
        walk.finish.signal()
        await engine.refresh()
        let failed = await engine.status()
        #expect(!failed.isScanning)
        #expect(failed.lastScanCompletedAt != nil)
        #expect(failed.error?.contains("Couldn’t scan files") == true)
        #expect(failed.error?.contains("Synthetic private filename") == false)
        walk.state.withLock { $0.fail = false }
        await engine.refresh()
        let recovered = await engine.status()
        #expect(recovered.error == nil)
        #expect(!recovered.isScanning)
        #expect(recovered.lastScanCompletedAt != failed.lastScanCompletedAt)
        #expect(!walk.state.withLock { $0.timedOut })
    }

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
        try reopened.retryFailed()
        let retried = try reopened.sourceStatuses()
        #expect(retried.first { $0.source == .messages } == SourceStatus(source: .messages, waiting: 1))
        #expect(retried.first { $0.source == .file } == statuses.first { $0.source == .file })
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
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: imported.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: imported.path)
        try await waitUntil("directory permission warning") {
            await engine.status().fileScanIssues.contains { $0.path == imported.path && $0.permissionDenied }
        }
        #expect(try engine.store.item(path: nested.path) != nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: imported.path)
        try await waitUntil("directory permission recovery") { await engine.status().fileScanIssues.isEmpty }
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

    private func waitUntil(_ label: String = #function, _ predicate: () async throws -> Bool) async throws {
        for _ in 0..<100 {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("A live file update did not reach the index within ten seconds: \(label)")
    }
}

private final class RetryWalk: Sendable {
    let started = DispatchSemaphore(value: 0)
    let finish = DispatchSemaphore(value: 0)
    let state = Mutex((count: 0, fail: true, timedOut: false))

    func walk(_ scanner: FileScanner) throws -> [Item] {
        let first = state.withLock { $0.count += 1; return $0.count == 1 }
        if first {
            started.signal()
            let result = finish.wait(timeout: .now() + 5)
            state.withLock { $0.timedOut = result == .timedOut }
        }
        if state.withLock({ $0.fail }) {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: "Synthetic private filename"])
        }
        return []
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { self.started.wait(); continuation.resume() }
        }
    }
}
