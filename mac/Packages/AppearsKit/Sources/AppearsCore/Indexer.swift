import Foundation
import AppearsMessages
import os

/// Engine logs, readable with `log stream --predicate 'subsystem == "rs.appea.appears"'`.
/// Paths are private (redacted unless the Mac allows private data); counts and timings are public.
let indexLog = Logger(subsystem: "rs.appea.appears", category: "indexer")

/// Where indexing is, for the menu bar glyph and Settings.
public struct IndexProgress: Sendable, Codable, Equatable {
    public enum Phase: String, Sendable, Codable {
        case idle, scanning, indexing, paused
    }

    public var phase: Phase = .idle
    /// Items found by the current scan so far.
    public var scanned = 0
    /// Items indexed in this run, of `total` waiting when it started.
    public var done = 0
    public var total = 0
    /// Why indexing is paused ("Low Power Mode"), if it is.
    public var pausedReason: String?

    public init() {}
}

/// Finds your files, notes and Messages, embeds them and keeps the index current.
public actor Indexer {
    public let store: IndexStore
    public let vectors: VectorIndex
    public let embedder: any Embedder
    public private(set) var settings: SourceSettings
    /// The settings it started with, readable without awaiting (for the file watcher).
    public nonisolated let initialSettings: SourceSettings
    public private(set) var progress = IndexProgress()
    /// Respect Low Power Mode and heat. The CLI turns this off.
    public var politeness = true
    private var noteCache: [String: NotesReader.Note] = [:]
    private let messagesReader: MessagesReader
    private var messageCursor: Int64?
    private var messagesCheckedAt: Date?
    private var scanningMessages = false
    private var messageHandles: [Int64: Handle] = [:]
    private var settingsRevision = 0
    private var messageSeconds = (read: 0.0, embed: 0.0, write: 0.0)
    private var onProgress: (@Sendable (IndexProgress) -> Void)?

    public init(store: IndexStore, vectors: VectorIndex, embedder: any Embedder, settings: SourceSettings, messagesURL: URL? = nil) {
        self.store = store
        self.vectors = vectors
        self.embedder = embedder
        self.settings = settings
        self.initialSettings = settings
        self.messagesReader = MessagesReader(url: messagesURL ?? ChatDatabase.defaultURL)
    }

    public func setProgressHandler(_ handler: @escaping @Sendable (IndexProgress) -> Void) {
        onProgress = handler
    }

    public func setPoliteness(_ value: Bool) { politeness = value }

    private func report(_ change: (inout IndexProgress) -> Void) {
        change(&progress)
        onProgress?(progress)
    }

    /// Applies new settings, removing anything they now exclude.
    public func update(settings: SourceSettings) throws {
        let old = self.settings
        self.settings = settings
        settingsRevision += 1
        var removed = try store.itemIDs(under: settings.excludes.filter { !old.excludes.contains($0) })
        if old.notes, !settings.notes { removed += try store.itemIDs(source: .notes) }
        if !settings.messages {
            removed += try store.itemIDs(source: .messages)
            messageCursor = nil
            messagesCheckedAt = nil
            messageHandles = [:]
        }
        if !settings.excludedKinds.isEmpty {
            // Cheap enough: kinds are rarely toggled.
            removed += try store.itemIDs(kinds: settings.excludedKinds)
        }
        vectors.remove(ids: try store.remove(itemIDs: removed))
    }

    // MARK: - Scanning

    /// Walks the home folder and included folders, recording new and changed files and
    /// removing ones that are gone. Returns how many files it found.
    @discardableResult
    public func scanFiles() throws -> Int {
        report { $0.phase = .scanning; $0.scanned = 0 }
        let scanStarted = Date()
        let scanner = FileScanner(settings: settings)
        var known = try store.paths(source: .file)
        var found = 0
        try scanner.scan { item in
            known.removeValue(forKey: item.path)
            try store.record(item, signature: FileScanner.signature(item))
            found += 1
            if found % 500 == 0 { report { $0.scanned = found } }
        }
        let removed = try store.remove(itemIDs: Array(known.values))
        vectors.remove(ids: removed)
        indexLog.info("Scan found \(found, privacy: .public) files (\(known.count, privacy: .public) gone) in \(Int(Date().timeIntervalSince(scanStarted)), privacy: .public)s")
        report { $0.scanned = found; $0.phase = .idle }
        return found
    }

    /// Reads Apple Notes, if they're on and readable. Returns how many notes it found.
    @discardableResult
    public func scanNotes() throws -> Int {
        guard settings.notes, settings.homeOverride == nil, NotesReader.isReadable else { return 0 }
        let notes = try NotesReader.read()
        var known = try store.paths(source: .notes)
        noteCache = [:]
        for note in notes {
            let path = "notes:\(note.identifier)"
            noteCache[path] = note
            known.removeValue(forKey: path)
            let item = Item(
                source: .notes, path: path, kind: .note, title: note.title, size: Int64(note.text.utf8.count),
                created: note.created, modified: note.modified, lastUsed: nil
            )
            try store.record(item, signature: FileScanner.signature(item))
        }
        vectors.remove(ids: try store.remove(itemIDs: Array(known.values)))
        return notes.count
    }

    /// A full pass reconciles deletions, unsends and photos downloaded since the last pass.
    /// Between full passes only new, edited and unsent messages are read. Text stays out of logs.
    @discardableResult
    public func scanMessages(full: Bool = true) async throws -> Int {
        guard settings.messages, settings.homeOverride == nil, !scanningMessages,
              messagesReader.isReadable else { return 0 }
        scanningMessages = true
        let showsScanProgress = progress.phase == .idle
        if showsScanProgress { report { $0.phase = .scanning; $0.scanned = 0 } }
        defer {
            scanningMessages = false
            if showsScanProgress, progress.phase == .scanning { report { $0.phase = .idle } }
        }
        let revision = settingsRevision
        let started = Date()
        let reconcile = full || messageCursor == nil
        var known = reconcile ? try store.sourceRecords(.messages) : [:]
        let hadIndex = !known.isEmpty
        messageHandles = try messagesReader.database.handles()
        let chats = Dictionary(uniqueKeysWithValues: try messagesReader.database.chats().map { ($0.rowID, $0) })
        var cursor: Int64 = reconcile ? 0 : messageCursor ?? 0
        var found = 0
        var changedAnchors: [Message] = []
        var changedChats: [Int64: [Date]] = [:]

        func record(_ message: Message) throws {
            var previous = reconcile ? [:] : try store.messageRecords(rowID: message.rowID)
            for entry in messagesReader.entries(for: message, chat: chats[message.chatID], settings: settings) {
                let old = reconcile ? known.removeValue(forKey: entry.item.path) : previous.removeValue(forKey: entry.item.path)
                if old?.signature != entry.signature {
                    try store.record(entry.item, signature: entry.signature)
                    if old != nil || hadIndex { changedAnchors.append(message) }
                }
                found += 1
            }
            if !reconcile {
                vectors.remove(ids: try store.remove(itemIDs: previous.values.map(\.id)))
                changedAnchors.append(message)
            }
        }

        while true {
            try Task.checkCancellation()
            guard revision == settingsRevision, settings.messages else { return found }
            let batch = try messagesReader.database.messages(after: cursor, limit: 500)
            guard !batch.isEmpty else { break }
            for message in batch { try record(message) }
            cursor = batch.map(\.rowID).max() ?? cursor
            if showsScanProgress, progress.phase == .scanning { report { $0.scanned = found } }
            await Task.yield()
        }
        if !reconcile, let checked = messagesCheckedAt {
            for message in try messagesReader.database.messages(editedAfter: checked.addingTimeInterval(-1)) {
                try record(message)
                changedAnchors.append(message)
            }
        }
        guard revision == settingsRevision, settings.messages else { return found }
        if reconcile {
            // A deleted message may also appear in neighbouring messages' stored context.
            for batch in Array(known.values.map(\.id)).chunked(500) {
                for item in try store.items(ids: Array(batch)).values {
                    if let reference = item.message { changedChats[reference.chatID, default: []].append(item.created) }
                }
            }
            vectors.remove(ids: try store.remove(itemIDs: known.values.map(\.id)))
        }
        for message in Dictionary(grouping: changedAnchors, by: \.rowID).values.compactMap(\.first) {
            changedChats[message.chatID, default: []].append(message.date)
        }
        for (chatID, dates) in changedChats {
            for date in Set(dates) {
                let neighbours = try messagesReader.database.messages(inChat: chatID, from: date.addingTimeInterval(-1_800), to: date.addingTimeInterval(1_800))
                try store.markMessagesPending(rowIDs: neighbours.map(\.rowID))
            }
        }
        messageCursor = cursor
        messagesCheckedAt = started
        return found
    }

    /// Files that FSEvents says changed: record them, or remove them if they're gone.
    public func filesChanged(_ paths: [String]) throws {
        let scanner = FileScanner(settings: settings)
        var removed: [Int64] = []
        for path in Set(paths) {
            if let item = scanner.item(at: URL(filePath: path)) {
                try store.record(item, signature: FileScanner.signature(item))
            } else if let existing = try store.item(path: path) {
                removed.append(existing.id)
            }
        }
        vectors.remove(ids: try store.remove(itemIDs: removed))
    }

    // MARK: - Indexing

    /// Indexes everything waiting, in batches, until nothing is left or the task is
    /// cancelled. Returns how many items it indexed.
    @discardableResult
    public func indexPending() async throws -> Int {
        let total = try store.counts().waiting
        guard total > 0 else { return 0 }
        report { $0.phase = .indexing; $0.done = 0; $0.total = total }
        let runStarted = Date()
        messageSeconds = (0, 0, 0)
        indexLog.info("Indexing run started: \(total, privacy: .public) waiting (priority \(Task.currentPriority.rawValue, privacy: .public))")
        var done = 0
        defer { report { $0.phase = .idle } }
        while !Task.isCancelled {
            if politeness, let reason = Self.pauseReason() {
                report { $0.phase = .paused; $0.pausedReason = reason }
                try await Task.sleep(for: .seconds(30))
                continue
            }
            let batch = try store.pending(limit: 16)
            if batch.isEmpty { break }
            report { $0.phase = .indexing; $0.pausedReason = nil }
            var handled = Set<Int64>()
            for item in batch where !handled.contains(item.id) {
                try Task.checkCancellation()
                let group = item.kind == .message
                    ? Array(batch.filter { $0.kind == .message && !handled.contains($0.id) }.prefix(8))
                    : [item]
                handled.formUnion(group.map(\.id))
                let started = Date()
                do {
                    try await withTimeout(seconds: Self.itemTimeout) {
                        if item.kind == .message { try await self.indexMessageTexts(group) }
                        else { try await self.index(item) }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // One bad file never stops the run: mark it and move on. It's retried when it changes.
                    indexLog.error("Couldn't index a \(item.kind.rawValue, privacy: .public) (\(item.size, privacy: .public) bytes): \(error.localizedDescription, privacy: .public) \(item.path, privacy: .private)")
                    for failed in group where (try? store.item(path: failed.path)?.id) == failed.id { try? store.markFailed(itemID: failed.id) }
                }
                let seconds = Date().timeIntervalSince(started)
                if seconds > 10 {
                    indexLog.notice("Slow \(item.kind.rawValue, privacy: .public): \(seconds, format: .fixed(precision: 1), privacy: .public)s for \(item.size, privacy: .public) bytes \(item.path, privacy: .private)")
                }
                done += group.count
                report { $0.done = done; $0.total = max($0.total, done) }
                if done % 100 == 0 {
                    let rate = Double(done) / Date().timeIntervalSince(runStarted)
                    indexLog.info("Indexed \(done, privacy: .public) of \(total, privacy: .public) (\(rate, format: .fixed(precision: 2), privacy: .public)/s)")
                    if messageSeconds.embed > 0 {
                        let seconds = messageSeconds
                        indexLog.info("Messages time: read \(seconds.read, format: .fixed(precision: 2), privacy: .public)s, embed \(seconds.embed, format: .fixed(precision: 2), privacy: .public)s, write \(seconds.write, format: .fixed(precision: 2), privacy: .public)s")
                    }
                }
            }
        }
        if let gemma = embedder as? any UnloadsVision { await gemma.unloadVision() }
        indexLog.info("Indexing run finished: \(done, privacy: .public) items in \(Int(Date().timeIntervalSince(runStarted)), privacy: .public)s")
        return done
    }

    /// Reads, embeds and stores one item. An unreadable item is marked so it isn't retried
    /// until it changes.
    func index(_ item: Item) async throws {
        let revision = settingsRevision
        guard item.source != .messages || settings.messages else { return }
        let extraction: Extraction?
        if item.source == .messages {
            extraction = await messagesReader.extraction(for: item, handles: messageHandles)
        } else if item.source == .notes {
            if noteCache[item.path] == nil { try scanNotes() }
            extraction = noteCache[item.path].map { Extractor.extract(noteText: $0.text, title: $0.title) }
        } else {
            extraction = await Extractor.extract(item)
        }
        guard revision == settingsRevision, try store.item(path: item.path)?.id == item.id else { return }
        guard let extraction, !extraction.isEmpty else {
            try store.markFailed(itemID: item.id)
            return
        }
        var units: [(unit: Unit, vector: [Float])] = []
        let title = item.source != .file ? item.title : "\(item.title) (\((item.folder as NSString).lastPathComponent))"
        if !extraction.texts.isEmpty {
            let documents = extraction.texts.map { EmbeddingDocument(title: title, text: $0.text) }
            var vectors: [[Float]] = []
            for batch in documents.chunked(8) { vectors += try await embedder.embed(documents: Array(batch)) }
            for (text, vector) in zip(extraction.texts, vectors) {
                units.append((Unit(kind: .text, locator: text.locator, text: text.text), vector))
            }
        }
        if !extraction.images.isEmpty, embedder.supportsImages {
            let vectors = try await embedder.embed(images: extraction.images.map(\.image))
            for (image, vector) in zip(extraction.images, vectors) {
                units.append((Unit(kind: .image, locator: image.locator, text: image.text), vector))
            }
        } else if !extraction.images.isEmpty {
            // Without an image model, images are found by their OCR text or name.
            let documents = extraction.images.map { EmbeddingDocument(title: title, text: $0.text.isEmpty ? item.title : $0.text) }
            let vectors = try await embedder.embed(documents: documents)
            for (image, vector) in zip(extraction.images, vectors) {
                units.append((Unit(kind: .text, locator: image.locator, text: image.text), vector))
            }
        }
        if item.source == .file, let lastUsed = LastUsed.date(path: item.path) {
            try store.touch(path: item.path, at: lastUsed)
        }
        // A source can be switched off while embedding awaits the GPU. Never put it back.
        guard revision == settingsRevision, try store.item(path: item.path)?.id == item.id else { return }
        try commit(item, units: units)
    }

    /// A Messages history has many small documents: send up to eight through the model at once.
    private func indexMessageTexts(_ items: [Item]) async throws {
        let revision = settingsRevision
        guard settings.messages else { return }
        let readStarted = Date()
        var prepared: [(item: Item, text: String)] = []
        let texts = try? messagesReader.texts(for: items, handles: messageHandles)
        for item in items {
            let text: String?
            if let texts { text = texts[item.id] }
            else {
                // A transient batch read failure shouldn't fail every message together.
                text = await messagesReader.extraction(for: item, handles: messageHandles)?.texts.first?.text
            }
            guard revision == settingsRevision, try store.item(path: item.path)?.id == item.id else { return }
            if let text { prepared.append((item, text)) }
            else { try store.markFailed(itemID: item.id) }
        }
        messageSeconds.read += Date().timeIntervalSince(readStarted)
        guard !prepared.isEmpty else { return }
        let embedStarted = Date()
        let embedded = try await embedder.embed(documents: prepared.map { EmbeddingDocument(title: $0.item.title, text: $0.text) })
        messageSeconds.embed += Date().timeIntervalSince(embedStarted)
        guard revision == settingsRevision else { return }
        let writeStarted = Date()
        for (entry, vector) in zip(prepared, embedded) {
            guard try store.item(path: entry.item.path)?.id == entry.item.id else { continue }
            try commit(entry.item, units: [(Unit(kind: .text, locator: .whole, text: entry.text), vector)])
        }
        messageSeconds.write += Date().timeIntervalSince(writeStarted)
    }

    private func commit(_ item: Item, units: [(unit: Unit, vector: [Float])]) throws {
        let (added, removed) = try store.replaceUnits(itemID: item.id, title: item.title, units: units)
        vectors.remove(ids: removed)
        for (unit, vector) in zip(added, units.map(\.vector)) {
            vectors.upsert(id: unit.id, kind: unit.kind, vector: vector)
        }
    }

    /// Longest one file may take before it's skipped (a hung PDF or image decoder).
    static let itemTimeout: Double = 120

    /// Low Power Mode, heat: reasons to wait before indexing more.
    static func pauseReason() -> String? {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return "Low Power Mode is on" }
        if info.thermalState == .serious || info.thermalState == .critical { return "The Mac is hot" }
        return nil
    }
}

/// Embedders that can free their image model between indexing runs.
public protocol UnloadsVision: Sendable {
    func unloadVision() async
}

struct TimeoutError: LocalizedError {
    let seconds: Double
    var errorDescription: String? { "Timed out after \(Int(seconds))s" }
}

/// Runs `work`, throwing `TimeoutError` if it takes longer than `seconds`. The work is
/// cancelled, but work that ignores cancellation keeps running in the background.
func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError(seconds: seconds)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
