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
    public var fileScanIssues: [FileScanIssue] = []
    /// Covers all enabled sources, even when indexing is already active.
    public var isScanning = false
    public var lastScanCompletedAt: Date?
    /// Whether the decision model is installed and switched on: results get a confidence and
    /// may signal on their own.
    public var decisions = false

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
    /// Payload: a JSON Bool, whether to use the decision model when it's installed.
    case decisions
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
    private let baseRecall: Recall
    /// The decision model once it's installed, and whether it's switched on.
    private let decisions = Mutex<(decider: (any Decider)?, enabled: Bool)>((nil, true))
    private let state = EngineState()
    private let searches = SearchCoordinator()
    private let sources: Mutex<(settings: SourceSettings, revision: UInt64)>

    public init(folder: URL, embedder: any Embedder, settings: SourceSettings,
                fileWalk: (@Sendable (FileScanner) throws -> [Item])? = nil, messagesURL: URL? = nil,
                decider: (any Decider)? = nil) throws {
        let embedder = ScheduledEmbedder(embedder)
        sources = Mutex((settings, 0))
        store = try IndexStore(url: folder.appending(path: "index.sqlite"))
        journal = try Journal(url: folder.appending(path: "journal.sqlite"))
        vectors = VectorIndex(dimension: embedder.dimension)
        self.embedder = embedder
        indexer = Indexer(store: store, vectors: vectors, embedder: embedder, settings: settings, fileWalk: fileWalk)
        baseRecall = Recall(store: store, vectors: vectors, embedder: embedder, messages: messagesURL.map(MessagesReader.init(url:)))
        decisions.withLock { $0.decider = decider }
        // A new model can't share vectors with the old one: start over.
        if try store.meta("model_id") != embedder.modelID {
            try store.removeAll()
            try store.setMeta("model_id", embedder.modelID)
        }
        if !settings.messages { try store.remove(itemIDs: store.itemIDs(source: .messages)) }
        try store.loadVectors(into: vectors)
    }

    /// Lookups as they run now: with the decision model when it's installed and switched on.
    public var recall: Recall {
        var recall = baseRecall
        recall.decider = decisions.withLock { $0.enabled ? $0.decider : nil }
        return recall
    }

    /// The decision model's files became available (after its download, for example).
    public func setDecider(_ decider: (any Decider)?) { decisions.withLock { $0.decider = decider } }
    public var hasDecider: Bool { decisions.withLock { $0.decider != nil } }

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
                if await self.scanSource(.messages, { try await self.indexer.scanMessages(full: tick % 10 == 0) }) > 0 { await self.indexPending() }
                // Notes have no file events we can watch from the sandbox: look every 10 minutes.
                if tick % 10 == 0, await self.scanSource(.notes, { try await self.indexer.scanNotes() }) > 0 { await self.indexPending() }
                // A full rescan every 6 hours catches anything FSEvents missed.
                if tick % 360 == 0 { await self.refresh() }
            }
        }
    }

    /// One full pass: scan files, notes and Messages, then index what's new.
    public func refresh() async {
        let scan = await requestRefresh()
        await scan.value
        await indexPending()
    }

    private func requestRefresh() async -> Task<Void, Never> {
        await state.requestScan { [self] in
            // A source failure never prevents the remaining sources from being checked.
            _ = await scanSource(.file) { try await self.indexer.scanFiles() }
            _ = await scanSource(.notes) { try await self.indexer.scanNotes() }
            _ = await scanSource(.messages) { try await self.indexer.scanMessages() }
        }
    }

    private func scanSource(_ source: ItemSource, _ scan: () async throws -> Int) async -> Int {
        do {
            let found = try await scan()
            await state.setScanError(nil, source: source)
            if source == .file { await state.setWatcherError(nil) }
            return found
        } catch is CancellationError { return 0 }
        catch {
            indexLog.error("Scan failed for \(source.rawValue, privacy: .public): \(error.localizedDescription, privacy: .private)")
            let name = source == .file ? "files" : source == .notes ? "Apple Notes" : "Messages"
            await state.setScanError("Couldn’t scan \(name). Other sources remain available. Use Scan now in Sources to retry.", source: source)
            return 0
        }
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
            indexLog.error("Indexing run stopped: \(error.localizedDescription, privacy: .private)")
            await state.setError("Indexing stopped: \(error.localizedDescription)")
        }
    }

    private func startWatching() async {
        let (settings, revision) = await indexer.watchConfiguration()
        let scanner = FileScanner(settings: settings)
        let roots = scanner.roots
        let watcher = FileWatcher(paths: roots, acceptsDirectory: scanner.shouldWatchFolder) { [weak self] changes in
            guard let self else { return }
            Task { await self.processFileChanges(changes) }
        }
        await state.keep(watcher, roots: roots, revision: revision)
    }

    func processFileChanges(_ changes: FileChanges) async {
        do {
            if changes.fullScan {
                try await indexer.scanFiles()
                await state.setScanError(nil, source: .file)
            } else {
                if !changes.directories.isEmpty { try await indexer.scanFiles(in: Array(changes.directories)) }
                try await indexer.filesChanged(Array(changes.files))
            }
            // A successful scoped update proves only that update recovered, not the
            // rest of the source. Only a full scan can clear its full-scan error.
            await state.setWatcherError(nil)
        } catch {
            let message = "Couldn’t check changed files. Use Scan now in Sources to retry."
            if changes.fullScan { await state.setScanError(message, source: .file) }
            else { await state.setWatcherError(message) }
        }
        await indexPending()
    }

    // MARK: - Calls

    public func status() async -> EngineStatus {
        var status = EngineStatus()
        status.ready = await state.ready
        status.counts = (try? store.counts()) ?? IndexCounts()
        status.progress = await indexer.progress
        status.fileScanIssues = await indexer.fileScanIssues
        (status.isScanning, status.lastScanCompletedAt) = await state.scanStatus
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
        status.decisions = decisions.withLock { $0.enabled && $0.decider != nil }
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
            let revision = sources.withLock { $0.revision }
            if let path = request.context.documentPath { try? store.touch(path: path) }
            let response = try await recall.run(request)
            guard sources.withLock({ $0.revision }) == revision else { throw CancellationError() }
            return try encoder.encode(response)
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
        case .decisions:
            let enabled = try decoder.decode(Bool.self, from: payload)
            decisions.withLock { $0.enabled = enabled }
            return Data("{}".utf8)
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
            try store.retryFailed()
            // Mark the scan active before acknowledging it, so the UI can't miss the start.
            let scan = await requestRefresh()
            Task.detached(priority: .medium) { await scan.value; await self.indexPending() }
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
    private var scanErrors: [ItemSource: String] = [:]
    private var watcherError: String?
    var error: String? { [.file, .notes, .messages].compactMap { scanErrors[$0] }.first ?? watcherError ?? indexingError }
    private var scan: Task<Void, Never>?
    private var lastScanCompletedAt: Date?
    var scanStatus: (Bool, Date?) { (scan != nil, lastScanCompletedAt) }
    private var watcher: FileWatcher?
    var watchedFolders: [String] = []
    private var watcherRevision = -1

    func setReady(_ value: Bool) { ready = value }
    func setError(_ value: String?) { indexingError = value }
    func setScanError(_ value: String?, source: ItemSource) { scanErrors[source] = value }
    func setWatcherError(_ value: String?) { watcherError = value }
    func requestScan(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        if let scan { return scan }
        let task = Task(priority: .medium) {
            await operation()
            scan = nil
            lastScanCompletedAt = Date()
        }
        scan = task
        return task
    }
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

/// Directory changes retain their scope; dropped events and root changes require recovery.
struct FileChanges: Sendable {
    var files = Set<String>()
    var directories = Set<String>()
    var fullScan = false

    init() {}

    init(paths: [String], flags: [FSEventStreamEventFlags], acceptsDirectory: (String) -> Bool) {
        for (path, rawFlag) in zip(paths, flags) {
            let flag = Int(rawFlag)
            if flag & (kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 { fullScan = true }
            else if flag & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0,
               acceptsDirectory(path) { fullScan = true }
            if flag & kFSEventStreamEventFlagItemIsDir != 0,
               flag & (kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed
                       | kFSEventStreamEventFlagItemChangeOwner | kFSEventStreamEventFlagItemInodeMetaMod) != 0,
               acceptsDirectory(path) { directories.insert(path) }
            if flag & kFSEventStreamEventFlagItemIsFile != 0,
               FileScanner.kind(forExtension: (path as NSString).pathExtension) != nil,
               acceptsDirectory((path as NSString).deletingLastPathComponent) { files.insert(path) }
        }
    }

    mutating func merge(_ other: FileChanges) {
        files.formUnion(other.files)
        directories.formUnion(other.directories)
        fullScan = fullScan || other.fullScan
    }

    var isEmpty: Bool { !fullScan && files.isEmpty && directories.isEmpty }
}

/// FSEvents for the current roots. Replacing the watcher drains its callback queue.
public final class FileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "rs.appea.filewatcher", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    public private(set) var isRunning = false

    // All mutable state is confined to the watcher's serial callback queue.
    private final class Callback: @unchecked Sendable {
        let handler: @Sendable (FileChanges) -> Void
        let acceptsDirectory: @Sendable (String) -> Bool
        let queue: DispatchQueue
        private var pending = FileChanges()
        private var scheduled = false

        init(queue: DispatchQueue, acceptsDirectory: @escaping @Sendable (String) -> Bool,
             handler: @escaping @Sendable (FileChanges) -> Void) {
            self.queue = queue
            self.handler = handler
            self.acceptsDirectory = acceptsDirectory
        }

        func receive(_ changes: FileChanges) {
            guard !changes.isEmpty else { return }
            pending.merge(changes)
            guard !scheduled else { return }
            scheduled = true
            // A bounded window combines bursts without postponing updates indefinitely.
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                let changes = self.pending
                self.pending = FileChanges()
                self.scheduled = false
                self.handler(changes)
            }
        }
    }

    init(paths: [String], acceptsDirectory: @escaping @Sendable (String) -> Bool = { _ in false },
         handler: @escaping @Sendable (FileChanges) -> Void) {
        queue.setSpecific(key: queueKey, value: 1)
        let callback = Callback(queue: queue, acceptsDirectory: acceptsDirectory, handler: handler)
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
            callback.receive(FileChanges(paths: Array(array.prefix(count)), flags: Array(UnsafeBufferPointer(start: flags, count: min(count, array.count))),
                                         acceptsDirectory: callback.acceptsDirectory))
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
