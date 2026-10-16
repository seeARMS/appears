import CoreServices
import Foundation
import Synchronization

/// What the engine reports to the app.
public struct EngineStatus: Sendable, Codable, Equatable {
    public var ready = false
    public var counts = IndexCounts()
    public var progress = IndexProgress()
    public var notesReadable = false
    public var messagesReadable = false
    /// Whether the engine could read the protected home folders (Desktop, Documents,
    /// Downloads). False usually means macOS is waiting on a permission.
    public var protectedFoldersReadable = false
    public var modelID = ""
    public var error: String?
    public var sources: [SourceStatus] = []
    public var watchedFolders: [String] = []
    public var unreadableFolders: [String] = []

    public init() {}
}

/// Counts and scan dates only. No source content or screen context enters status.
public struct SourceStatus: Sendable, Codable, Equatable, Identifiable {
    public var id: ItemSource { source }
    public var source: ItemSource
    public var indexed: Int
    public var waiting: Int
    public var unreadable: Int
    public var lastChecked: Date?

    public init(source: ItemSource, indexed: Int = 0, waiting: Int = 0, unreadable: Int = 0, lastChecked: Date? = nil) {
        self.source = source
        self.indexed = indexed
        self.waiting = waiting
        self.unreadable = unreadable
        self.lastChecked = lastChecked
    }
}

/// Feedback on one suggestion from the panel.
public struct FeedbackEvent: Sendable, Codable {
    public var entryID: Int64
    public var itemID: Int64
    public var position: Int
    public var outcome: Outcome

    public init(entryID: Int64, itemID: Int64, position: Int, outcome: Outcome) {
        self.entryID = entryID
        self.itemID = itemID
        self.position = position
        self.outcome = outcome
    }
}

/// The methods the app calls on the engine. Payloads and replies are JSON.
public enum EngineMethod: String, Sendable {
    case status, related, search, cancelSearch, settings, feedback, log, stats, touch, rescan, deleteIndex, deleteJournal
}

/// The XPC interface. One generic call keeps the Objective-C surface tiny; the Swift types
/// on either side are Codable.
@objc public protocol EngineXPC {
    func call(_ method: String, payload: Data, reply: @escaping @Sendable (Data?, String?) -> Void)
}

/// Indexing, search and the journal: everything the sandboxed engine does. The CLI runs it
/// in-process; the app talks to it over XPC (`mac/Engine`).
public final class Engine: Sendable {
    public let store: IndexStore
    public let vectors: VectorIndex
    public let embedder: any Embedder
    public let indexer: Indexer
    public let journal: Journal
    public let recall: Recall
    private let state = EngineState()
    private let searches = SearchCoordinator()
    private let sources: Mutex<(settings: SourceSettings, revision: UInt64)>

    public init(folder: URL, embedder: any Embedder, settings: SourceSettings) throws {
        let embedder = ScheduledEmbedder(embedder)
        sources = Mutex((settings, 0))
        store = try IndexStore(url: folder.appending(path: "index.sqlite"))
        journal = try Journal(url: folder.appending(path: "journal.sqlite"))
        vectors = VectorIndex(dimension: embedder.dimension)
        self.embedder = embedder
        indexer = Indexer(store: store, vectors: vectors, embedder: embedder, settings: settings)
        recall = Recall(store: store, vectors: vectors, embedder: embedder)
        // A new model can't share vectors with the old one: start over.
        if try store.meta("model_id") != embedder.modelID {
            try store.removeAll()
            try store.setMeta("model_id", embedder.modelID)
        }
        if !settings.messages { try store.remove(itemIDs: store.itemIDs(source: .messages)) }
        try store.loadVectors(into: vectors)
    }

    // MARK: - Running

    /// Scans, indexes, then keeps up with changes until the process ends.
    ///
    /// Indexing runs at medium priority, not utility: the model runs on the GPU, and macOS
    /// deprioritizes GPU work from utility threads, which made indexing about 3× slower than
    /// the same work in the CLI (measured 2026-10-15). It still pauses for Low Power Mode and heat.
    public func start() {
        Task { await state.setReady(true) }
        Task.detached(priority: .medium) { [self] in
            await self.startWatching()
            await self.refresh()
            var tick = 0
            while true {
                try? await Task.sleep(for: .seconds(60))
                tick += 1
                // The watchdog: anything waiting and nothing running means a run ended early.
                if (try? self.store.counts().waiting) ?? 0 > 0 { await self.indexPending() }
                // New messages each minute; a full pass also catches deletions and local photos.
                if (try? await self.indexer.scanMessages(full: tick % 10 == 0)) ?? 0 > 0 { await self.indexPending() }
                // Notes have no file events we can watch from the sandbox: look every 10 minutes.
                if tick % 10 == 0, (try? await self.indexer.scanNotes()) ?? 0 > 0 { await self.indexPending() }
                // A full rescan every 6 hours catches anything FSEvents missed.
                if tick % 360 == 0 { await self.refresh() }
            }
        }
    }

    /// One full pass: scan files, notes and Messages, then index what's new.
    public func refresh() async {
        do {
            try await indexer.scanFiles()
            try await indexer.scanNotes()
            try await indexer.scanMessages()
            await state.setScanError(nil)
        } catch {
            indexLog.error("Scan failed: \(error.localizedDescription, privacy: .public)")
            await state.setScanError("Scanning failed: \(error.localizedDescription)")
        }
        await indexPending()
    }

    /// Indexes what's waiting, unless a run is already going.
    public func indexPending() async {
        guard await state.beginIndexing() else { return }
        defer { Task { await state.endIndexing() } }
        do {
            // File events arrive on a utility queue. Pin the indexing work itself so a
            // file event winning the startup race can't lower the whole run's GPU priority.
            _ = try await Task.detached(priority: .medium) { [self] in
                try await indexer.indexPending()
            }.value
            await state.setError(nil)
        } catch is CancellationError {} catch {
            indexLog.error("Indexing run stopped: \(error.localizedDescription, privacy: .public)")
            await state.setError("Indexing stopped: \(error.localizedDescription)")
        }
    }

    private func startWatching() async {
        let (settings, revision) = await indexer.watchConfiguration()
        let scanner = FileScanner(settings: settings)
        let roots = scanner.roots
        let watcher = FileWatcher(paths: roots, acceptsDirectory: scanner.shouldWatchFolder) { [weak self] paths, rescan in
            guard let self else { return }
            Task {
                do {
                    if rescan { try await self.indexer.scanFiles() }
                    else { try await self.indexer.filesChanged(paths) }
                    await self.indexPending()
                } catch {
                    await self.state.setScanError("Couldn’t check changed files. Use Scan now in Sources to retry.")
                }
            }
        }
        await state.keep(watcher, roots: roots, revision: revision)
    }

    // MARK: - Calls

    public func status() async -> EngineStatus {
        var status = EngineStatus()
        status.ready = await state.ready
        status.counts = (try? store.counts()) ?? IndexCounts()
        status.progress = await indexer.progress
        status.notesReadable = NotesReader.isReadable
        let sources = self.sources.withLock { $0.settings }
        status.messagesReadable = sources.messages && sources.homeOverride == nil && MessagesReader().isReadable
        let home = FileScanner.realHome
        status.protectedFoldersReadable = (try? FileManager.default.contentsOfDirectory(atPath: home + "/Documents")) != nil
        status.unreadableFolders = sources.includes.filter {
            (try? FileManager.default.contentsOfDirectory(atPath: $0)) == nil
        }
        status.modelID = embedder.modelID
        status.error = await state.error
        status.sources = (try? store.sourceStatuses()) ?? []
        status.watchedFolders = await state.watchedFolders
        return status
    }

    public func handle(_ method: EngineMethod, payload: Data) async throws -> Data {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        switch method {
        case .status:
            return try encoder.encode(await status())
        case .related:
            let request = try decoder.decode(RecallRequest.self, from: payload)
            if let path = request.context.documentPath { try? store.touch(path: path) }
            return try encoder.encode(try await recall.run(request))
        case .search:
            let request = try decoder.decode(SearchRequest.self, from: payload)
            let trace = SearchTrace()
            do {
                let operation: @Sendable () async throws -> RecallResponse = { [self] in
                    try await SearchTrace.$current.withValue(trace) {
                        let configuration = sources.withLock { $0 }
                        let response = try await Search(recall: recall).run(request, sources: configuration.settings)
                        try Task.checkCancellation()
                        // A settings update can remove a source while embedding is in flight.
                        guard sources.withLock({ $0.revision }) == configuration.revision else { throw CancellationError() }
                        return response
                    }
                }
                var response: RecallResponse
                if let token = request.token { response = try await searches.run(token, operation: operation) }
                else { response = try await operation() }
                response.timings = trace.finish(outcome: "completed")
                return try encoder.encode(response)
            } catch {
                _ = trace.finish(outcome: error is CancellationError ? "cancelled" : "failed")
                throw error
            }
        case .cancelSearch:
            await searches.cancel(try decoder.decode(SearchToken.self, from: payload))
            return Data("{}".utf8)
        case .settings:
            let settings = try decoder.decode(SourceSettings.self, from: payload)
            let changed = sources.withLock { value in
                guard value.settings != settings else { return false }
                value = (settings, value.revision + 1)
                return true
            }
            try await indexer.update(settings: settings)
            if changed {
                await startWatching()
                Task.detached(priority: .medium) { await self.refresh() }
            }
            return Data("{}".utf8)
        case .feedback:
            let event = try decoder.decode(FeedbackEvent.self, from: payload)
            try journal.record(event.outcome, entryID: event.entryID, itemID: event.itemID, position: event.position)
            if event.outcome == .blocked { try store.setNeverShow(itemID: event.itemID) }
            if event.outcome == .opened || event.outcome == .dragged {
                if let item = try store.items(ids: [event.itemID]).values.first { try store.touch(path: item.path) }
            }
            return Data("{}".utf8)
        case .log:
            let entry = try decoder.decode(JournalEntry.self, from: payload)
            return try encoder.encode(try journal.log(entry))
        case .stats:
            let days = (try? decoder.decode(Int.self, from: payload)) ?? 7
            return try encoder.encode(try journal.stats(days: days))
        case .touch:
            let path = try decoder.decode(String.self, from: payload)
            try store.touch(path: path)
            return Data("{}".utf8)
        case .rescan:
            Task.detached(priority: .medium) { await self.refresh() }
            return Data("{}".utf8)
        case .deleteIndex:
            try store.removeAll()
            try store.setMeta("model_id", embedder.modelID)
            vectors.removeAll()
            Task.detached(priority: .medium) { await self.refresh() }
            return Data("{}".utf8)
        case .deleteJournal:
            try journal.deleteAll()
            return Data("{}".utf8)
        }
    }
}

private actor EngineState {
    var ready = false
    var indexing = false
    private var indexingError: String?
    private var scanError: String?
    var error: String? { scanError ?? indexingError }
    private var watcher: FileWatcher?
    var watchedFolders: [String] = []
    private var watcherRevision = -1

    func setReady(_ value: Bool) { ready = value }
    func setError(_ value: String?) { indexingError = value }
    func setScanError(_ value: String?) { scanError = value }
    func beginIndexing() -> Bool {
        if indexing { return false }
        indexing = true
        return true
    }
    func endIndexing() { indexing = false }
    func keep(_ watcher: FileWatcher, roots: [String], revision: Int) {
        guard revision >= watcherRevision else { return }
        watcherRevision = revision
        self.watcher = watcher
        watchedFolders = watcher.isRunning ? roots : []
    }
}

/// FSEvents for the current roots. Replacing the watcher drains its callback queue.
public final class FileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "rs.appea.filewatcher", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    public private(set) var isRunning = false

    private final class Callback: Sendable {
        let handler: @Sendable ([String], Bool) -> Void
        let acceptsDirectory: @Sendable (String) -> Bool
        init(acceptsDirectory: @escaping @Sendable (String) -> Bool, handler: @escaping @Sendable ([String], Bool) -> Void) {
            self.handler = handler
            self.acceptsDirectory = acceptsDirectory
        }
    }

    public init(paths: [String], acceptsDirectory: @escaping @Sendable (String) -> Bool = { _ in false },
                handler: @escaping @Sendable ([String], Bool) -> Void) {
        queue.setSpecific(key: queueKey, value: 1)
        let callback = Callback(acceptsDirectory: acceptsDirectory, handler: handler)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Callback>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                if let info { Unmanaged<Callback>.fromOpaque(info).release() }
            }, copyDescription: nil
        )
        let receive: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let callback = Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var changed: [String] = []
            var rescan = false
            for index in 0..<min(count, array.count) {
                let flag = Int(flags[index])
                let path = array[index]
                if flag & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0 {
                    if callback.acceptsDirectory(path) { rescan = true }
                }
                if flag & kFSEventStreamEventFlagItemIsDir != 0,
                   flag & (kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed) != 0,
                   callback.acceptsDirectory(path) { rescan = true }
                if flag & kFSEventStreamEventFlagItemIsFile != 0,
                   FileScanner.kind(forExtension: (path as NSString).pathExtension) != nil { changed.append(path) }
            }
            if rescan || !changed.isEmpty { callback.handler(changed, rescan) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                           | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        stream = FSEventStreamCreate(nil, receive, &context, paths as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            isRunning = FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            let stop = {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            if DispatchQueue.getSpecific(key: queueKey) != nil { stop() }
            else { queue.sync(execute: stop) }
        }
    }
}
