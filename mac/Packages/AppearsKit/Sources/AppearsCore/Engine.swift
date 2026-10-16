import CoreServices
import Foundation

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

    public init() {}
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
    case status, related, search, settings, feedback, log, stats, touch, rescan, deleteIndex, deleteJournal
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

    public init(folder: URL, embedder: any Embedder, settings: SourceSettings) throws {
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
        startWatching()
        Task.detached(priority: .medium) { [self] in
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
        } catch {
            indexLog.error("Scan failed: \(error.localizedDescription, privacy: .public)")
            await state.setError("Scanning failed: \(error.localizedDescription)")
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

    private func startWatching() {
        let roots = FileScanner(settings: indexer.initialSettings).roots
        let watcher = FileWatcher(paths: roots) { [self] paths in
            Task {
                try? await self.indexer.filesChanged(paths)
                await self.indexPending()
            }
        }
        state.keep(watcher)
    }

    // MARK: - Calls

    public func status() async -> EngineStatus {
        var status = EngineStatus()
        status.ready = await state.ready
        status.counts = (try? store.counts()) ?? IndexCounts()
        status.progress = await indexer.progress
        status.notesReadable = NotesReader.isReadable
        let sources = await indexer.settings
        status.messagesReadable = sources.messages && sources.homeOverride == nil && MessagesReader().isReadable
        let home = FileScanner.realHome
        status.protectedFoldersReadable = (try? FileManager.default.contentsOfDirectory(atPath: home + "/Documents")) != nil
        status.modelID = embedder.modelID
        status.error = await state.error
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
            return try encoder.encode(try await Search(recall: recall).run(request, sources: await indexer.settings))
        case .settings:
            let settings = try decoder.decode(SourceSettings.self, from: payload)
            let changed = await indexer.settings != settings
            try await indexer.update(settings: settings)
            if changed { Task.detached(priority: .medium) { await self.refresh() } }
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
    var error: String?
    nonisolated(unsafe) var watcher: FileWatcher?

    func setReady(_ value: Bool) { ready = value }
    func setError(_ value: String?) { error = value }
    func beginIndexing() -> Bool {
        if indexing { return false }
        indexing = true
        return true
    }
    func endIndexing() { indexing = false }
    nonisolated func keep(_ watcher: FileWatcher) { self.watcher = watcher }
}

/// FSEvents on the home folder: reports changed file paths, batched every couple of seconds.
public final class FileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let handler: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "rs.appea.filewatcher", qos: .utility)

    public init(paths: [String], handler: @escaping @Sendable ([String]) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var changed: [String] = []
            for index in 0..<count {
                let flag = Int(flags[index])
                if flag & kFSEventStreamEventFlagItemIsFile != 0 { changed.append(array[index]) }
            }
            // Skip the noise of Library and hidden folders early.
            changed = changed.filter {
                !$0.contains("/Library/") && !$0.contains("/.")
                    && FileScanner.kind(forExtension: ($0 as NSString).pathExtension) != nil
            }
            if !changed.isEmpty { watcher.handler(changed) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0, flags
        )
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
