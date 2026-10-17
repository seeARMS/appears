import AppKit
import AppearsContext
import AppearsCore
import Foundation
import os

/// Everything the menu bar item and the panel show, and the loop that decides when to look.
///
/// The loop: the Accessibility observer reports a change → wait for it to settle → note the
/// "topic" (app, window, document, URL) and when it started → after reading or a typing
/// pause, ask the engine (ambient) → if the answer is confident and the signal gap allows,
/// change the glyph. Nothing else happens until you look.
@MainActor @Observable
final class AppModel {
    var settings = AppSettings()
    let updater = Updater()
    let engine = EngineClient()
    let contacts: ContactDirectory

    init(contacts: ContactDirectory = ContactDirectory()) {
        self.contacts = contacts
    }
    @ObservationIgnored let modelDownloader = ModelDownloadClient()
    private(set) var modelDownload = ModelDownloadStatus()
    @ObservationIgnored let reader = ContextReader()
    @ObservationIgnored let calendar = CalendarWatcher()
    @ObservationIgnored private var policy = SurfacePolicy()
    @ObservationIgnored private var ambientLookups = AmbientLookupSchedule()

    enum Glyph: Equatable {
        case idle, working, found, paused, needsSetup
    }

    /// One set of suggestions in the panel.
    struct Shown {
        var entryID: Int64?
        var mode: JournalEntry.Mode
        var bundleID = ""
        var appName: String
        var windowTitle: String
        var fingerprint: String
        /// Stable, salted document/conversation identity for item deduplication.
        var topic = ""
        var suggestions: [Suggestion]
        /// Matching names and terms, used only in memory to emphasize source excerpts.
        var evidenceTerms: [String] = []
        var interacted = false
        var at = Date()
        /// Set when this is for an upcoming meeting rather than a window. In memory only.
        var meeting: CalendarEvent?
    }

    private(set) var glyph: Glyph = .idle
    private(set) var status: EngineStatus?
    private(set) var engineStatusError: String?
    private(set) var isRequestingScan = false
    private(set) var scanRequestMessage: String?
    private(set) var scanRequestError: String?
    @ObservationIgnored private var awaitingScanCompletion = false
    @ObservationIgnored private var scanRequestedAfter: Date?
    let loginItem = LoginItem()
    var sourcePreview: Suggestion?
    /// What the panel shows.
    private(set) var shown: Shown? {
        didSet { if shown?.at != oldValue?.at { sourcePreview = nil } }
    }
    /// An ambient result waiting behind the glyph.
    private(set) var waiting: Shown?
    private(set) var isPulling = false
    /// The highlighted card, for the keyboard.
    var selectedIndex = 0
    private(set) var pullError: String?
    private(set) var accessibilityTrusted = ContextReader.isTrusted
    /// Why the last context wasn't used, for the panel's footer ("password field").
    private(set) var skippedReason: String?

    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var dwellTask: Task<Void, Never>?
    @ObservationIgnored private var signalTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private(set) var sourcesUpdate: Task<Void, Never>?
    @ObservationIgnored private var meetingExpiry: Task<Void, Never>?
    private struct PendingAmbient {
        let id = UUID()
        let context: ContextSnapshot
        let suggestions: [Suggestion]
        let evidenceTerms: [String]
        let meeting: CalendarEvent?
        let topic: String
    }
    @ObservationIgnored private var pendingAmbient: PendingAmbient?

    /// Called when the panel should open or update (the status item owns the panel).
    @ObservationIgnored var onShow: ((_ makeKey: Bool) -> Void)?

    static let contextResultLimit = 10
    /// Keep the ambient discovery gate on the same first three candidates. A longer list
    /// must not make the menu bar dot appear for a context that used to stay quiet.
    private static let ambientCandidateLimit = 3

    /// Broaden the panel only after the original ambient candidates clear the policy.
    /// Keep those confident matches first, followed by the other ranked candidates.
    static func ambientPanelSuggestions(_ candidates: [Suggestion], isConfident: (Double) -> Bool,
                                        maySuggest: (Suggestion) -> Bool = { _ in true }) -> [Suggestion] {
        let confident = candidates.prefix(ambientCandidateLimit).filter { isConfident($0.confidence) && maySuggest($0) }
        guard !confident.isEmpty else { return [] }
        let confidentIDs = Set(confident.map(\.id))
        let remaining = candidates.filter { maySuggest($0) && !confidentIDs.contains($0.id) }
        return Array((confident + remaining).prefix(contextResultLimit))
    }

    /// `-demo <folder>`: index that folder (demo/files) instead of your home folder, in a
    /// separate index. For trying Appears and for screenshots.
    static let demoFolder: String? = {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "-demo"), args.indices.contains(index + 1) else { return nil }
        return URL(filePath: args[index + 1]).standardizedFileURL.path
    }()

    /// `-ask "<text>"`: once the engine is ready, ask with this text as the context (as if a
    /// window showed it) and open the panel. For testing without the Accessibility permission.
    static let scriptedAsk: String? = {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "-ask"), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }()

    /// `-search "<text>"`: open typed search, useful with the isolated demo index.
    static let scriptedSearch: String? = {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "-search"), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }()

    /// The source settings sent to the engine (demo mode replaces home and skips Notes and Messages).
    var engineSources: SourceSettings {
        var sources = settings.sources
        if let demo = Self.demoFolder {
            sources.homeOverride = demo
            sources.notes = false
        }
        return sources
    }

    func start() {
        contacts.start(enabled: settings.sources.messages && Self.demoFolder == nil)
        policy = SurfacePolicy(settings: settings.policySettings)
        reader.onChange = { [weak self] change in self?.contextChanged(change) }
        reader.start()
        calendar.lead = settings.calendarLead
        calendar.onDue = { [weak self] event in Task { await self?.meetingCheck(event) } }
        startCalendar()
        statusTask = Task { [weak self] in
            if let self { self.modelDownload = await self.modelDownloader.update(.start) }
            // Settings first, so the engine loads with them.
            if let self { await self.engine.send(.settings, self.engineSources) }
            if let text = Self.scriptedAsk {
                Task { [weak self] in await self?.scriptedPull(text) }
            }
            while !Task.isCancelled {
                await self?.refreshStatus()
                let busy = self?.status.map { $0.isScanning || $0.progress.phase != .idle || !$0.ready } ?? true
                try? await Task.sleep(for: .seconds(self?.modelDownload.phase != .ready ? 1 : (busy ? 3 : 20)))
            }
        }
        contextChanged()
    }

    func refreshStatus() async {
        contacts.checkAuthorization()
        accessibilityTrusted = ContextReader.isTrusted
        if accessibilityTrusted { reader.start() }
        // Calendar access granted in System Settings since launch.
        if settings.calendarContext, !calendar.isRunning, Self.demoFolder == nil, CalendarWatcher.access == .granted { startCalendar() }
        let wasReady = modelDownload.phase == .ready
        modelDownload = await modelDownloader.update(.status)
        if modelDownload.phase == .waiting { modelDownload = await modelDownloader.update(.start) }
        if modelDownload.phase == .ready {
            if !wasReady {
                await engine.send(.settings, engineSources)
                contextChanged()
            }
            do {
                status = try await engine.call(.status, EngineClient.Empty(), as: EngineStatus.self)
                engineStatusError = nil
                if awaitingScanCompletion, let status {
                    if status.isScanning {
                        scanRequestMessage = "Scanning enabled sources… Existing results remain searchable."
                    } else if status.lastScanCompletedAt != scanRequestedAfter {
                        awaitingScanCompletion = false
                        if status.error != nil { scanRequestMessage = "Scan finished. Some sources need attention." }
                        else if !status.fileScanIssues.isEmpty {
                            let count = status.fileScanIssues.count
                            scanRequestMessage = "Scan complete. \(count.formatted()) \(count == 1 ? "path" : "paths") skipped; see Sources for details."
                        } else { scanRequestMessage = "Scan complete. New items will be indexed automatically." }
                    }
                }
            } catch {
                status = nil
                awaitingScanCompletion = false
                scanRequestMessage = nil
                engineStatusError = "The search engine isn’t responding. Try again, or reopen Appears."
            }
        }
        updateGlyph()
    }

    func retryModelDownload() {
        Task { modelDownload = await modelDownloader.update(.retry); updateGlyph() }
    }

    private func updateGlyph() {
        if !accessibilityTrusted {
            glyph = .needsSetup
        } else if settings.isPaused {
            glyph = .paused
        } else if modelDownload.phase == .failed || engineStatusError != nil || (status?.ready == false && status?.error != nil) {
            glyph = .needsSetup
        } else if modelDownload.phase != .ready {
            glyph = .working
        } else if waiting != nil {
            glyph = .found
        } else if let status, status.ready, status.progress.phase == .idle {
            glyph = .idle
        } else {
            glyph = .working
        }
    }

    // MARK: - The context loop

    private func contextChanged(_ change: ContextReader.Change = .context) {
        settleTask?.cancel()
        // Stop a pending lookup immediately while typing, and invalidate any answer in flight.
        dwellTask?.cancel()
        if pendingAmbient?.meeting == nil {
            signalTask?.cancel()
        }
        ambientLookups.didChange(textEdited: change == .textEdited, navigation: change == .navigation)
        let delay = ambientLookups.settleDelay()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.settled()
        }
    }

    /// The context has stopped changing. Editing bypasses the reading dwell.
    private func settled() {
        // Use the same URL-bearing fingerprint as the search/cache, so a harmless
        // browser focus event cannot discard a result waiting for its signal timer.
        guard settings.onboarded, settings.ambientMode != .off, !settings.isPaused,
              let captured = reader.capture(includeBrowserURL: true) else { return }
        let snapshot = captured.snapshot
        if let path = snapshot.documentPath {
            // Files you have open count as recently used.
            Task { await engine.send(.touch, path) }
        }
        // A suggestion for the old context is stale now. One for a meeting waits for the meeting.
        if let waiting, waiting.meeting == nil, waiting.fingerprint != snapshot.fingerprint(salt: settings.salt) {
            if !waiting.interacted { record(.ignored, for: waiting, item: waiting.suggestions.first, position: 0) }
            self.waiting = nil
        }
        if let pending = pendingAmbient, pending.meeting == nil {
            if pending.context.fingerprint(salt: settings.salt) == snapshot.fingerprint(salt: settings.salt) {
                // A selection/focus notification may leave the context unchanged. Its
                // already-completed search must not lose the scheduled signal.
                signalTask = Task { [weak self] in await self?.surfacePending() }
            } else {
                pendingAmbient = nil
            }
        }
        updateGlyph()
        scheduleAmbient(for: snapshot)
    }

    private func scheduleAmbient(for snapshot: ContextSnapshot) {
        dwellTask?.cancel()
        guard settings.ambientMode != .off else { return }
        guard let delay = ambientLookups.delay(fingerprint: snapshot.fingerprint(salt: settings.salt),
                                              topic: snapshot.topicFingerprint(salt: settings.salt), requiredDwell: settings.dwell) else { return }
        dwellTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.ambientCheck()
        }
    }

    /// Search promptly, even during the signal cooldown.
    private func ambientCheck() async {
        guard modelDownload.phase == .ready, settings.ambientMode != .off, !settings.isPaused, accessibilityTrusted,
              waiting?.meeting == nil, pendingAmbient?.meeting == nil,
              let captured = reader.capture(includeBrowserURL: true) else { return }
        if let reason = Exclusions.reason(for: captured, excludedApps: Set(settings.excludedApps), allowUnknownPrivacy: settings.ambientInSafari) {
            skippedReason = reason
            return
        }
        // Short composed questions and pictures can both be useful without 80 characters.
        guard captured.snapshot.hasAmbientText || captured.snapshot.showsPicture else { return }
        let fingerprint = captured.snapshot.fingerprint(salt: settings.salt)
        guard let response = try? await engine.related(RecallRequest(context: captured.snapshot, trigger: .ambient, limit: Self.contextResultLimit)) else { return }
        // The context may have moved on while the engine worked.
        guard !Task.isCancelled, !settings.isPaused, settings.ambientMode != .off,
              let current = reader.capture(includeBrowserURL: true),
              current.snapshot.fingerprint(salt: settings.salt) == fingerprint else { return }
        ambientLookups.didFinish(fingerprint: fingerprint)
        await queueAmbient(response.suggestions, context: captured.snapshot, evidenceTerms: response.query.entities + response.query.rareTerms)
    }

    /// Cache results in memory until a signal is eligible. Context changes cancel this
    /// one-shot timer and replace the cache with the latest draft's results.
    private func queueAmbient(_ suggestions: [Suggestion], context: ContextSnapshot, evidenceTerms: [String], meeting: CalendarEvent? = nil) async {
        guard meeting != nil || (waiting?.meeting == nil && pendingAmbient?.meeting == nil) else { return }
        signalTask?.cancel()
        let salt = settings.salt + (meeting.map { $0.id + String($0.start.timeIntervalSince1970) } ?? "")
        pendingAmbient = PendingAmbient(context: context, suggestions: suggestions, evidenceTerms: evidenceTerms, meeting: meeting,
                                        topic: context.topicFingerprint(salt: salt))
        await surfacePending()
    }

    private func surfacePending() async {
        guard let pending = pendingAmbient, !Task.isCancelled,
              settings.ambientMode != .off, !settings.isPaused else { return }
        let context = pending.context
        let fingerprint = context.fingerprint(salt: settings.salt)
        if let meeting = pending.meeting {
            guard settings.calendarContext, meeting.start > Date() else { pendingAmbient = nil; return }
        } else {
            guard waiting?.meeting == nil,
                  let current = reader.capture(includeBrowserURL: true),
                  current.snapshot.fingerprint(salt: settings.salt) == fingerprint,
                  Exclusions.reason(for: current, excludedApps: Set(settings.excludedApps), allowUnknownPrivacy: settings.ambientInSafari) == nil else {
                pendingAmbient = nil
                return
            }
        }
        policy.settings = settings.policySettings
        let suggestions = Self.ambientPanelSuggestions(pending.suggestions, isConfident: policy.isConfident) {
            policy.maySuggest(itemID: $0.item.id, topic: pending.topic)
        }
        guard !suggestions.isEmpty else { pendingAmbient = nil; return }
        let delay = policy.signalDelay()
        if delay > 0 {
            signalTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await self?.surfacePending()
            }
            return
        }
        let mode: JournalEntry.Mode = settings.ambientMode == .on ? .ambient : .shadow
        var entry = Shown(mode: mode, bundleID: context.bundleID, appName: context.appName,
                          windowTitle: context.windowTitle, fingerprint: fingerprint, topic: pending.topic,
                          suggestions: suggestions, evidenceTerms: pending.evidenceTerms, meeting: pending.meeting)
        entry.entryID = await engine.log(journalEntry(entry, dwell: pending.meeting == nil ? ambientLookups.dwell() : 0, context: context))
        guard !Task.isCancelled, pendingAmbient?.id == pending.id, !settings.isPaused,
              settings.ambientMode == (mode == .ambient ? .on : .shadow) else { return }
        pendingAmbient = nil
        policy.didSurface(itemIDs: suggestions.map { $0.item.id }, topic: pending.topic)
        if mode == .ambient {
            if let waiting, !waiting.interacted { record(.ignored, for: waiting, item: waiting.suggestions.first, position: 0) }
            waiting = entry
            updateGlyph()
            if let meeting = pending.meeting {
                expireMeeting(entry, at: min(meeting.end, meeting.start.addingTimeInterval(10 * 60)))
            }
        }
    }

    // MARK: - Meetings

    /// A meeting is coming up: look for what you already have about it, quietly. The same
    /// policy as a window (the threshold, signal gap and item deduplication), minus the dwell: the
    /// lead time is the moment. Its suggestion waits behind the glyph until shortly after the
    /// meeting starts, whatever window you're in.
    private func meetingCheck(_ event: CalendarEvent) async {
        guard modelDownload.phase == .ready, settings.calendarContext, settings.ambientMode != .off, !settings.isPaused,
              settings.onboarded || CalendarWatcher.isInjecting else { return }
        let snapshot = event.snapshot()
        guard let response = try? await engine.related(RecallRequest(context: snapshot, trigger: .ambient, limit: Self.contextResultLimit)) else { return }
        policy.settings = settings.policySettings
        let confident = response.suggestions.filter { policy.isConfident($0.confidence) }
        Self.log.info("Looked ahead to a meeting: top confidence \(response.confidence, format: .fixed(precision: 2), privacy: .public), \(confident.count, privacy: .public) confident")
        guard !confident.isEmpty, event.start > Date() else { return }

        await queueAmbient(response.suggestions, context: snapshot, evidenceTerms: response.query.entities + response.query.rareTerms, meeting: event)
    }

    /// A meeting's suggestion fades shortly after the meeting starts.
    private func expireMeeting(_ entry: Shown, at date: Date) {
        meetingExpiry?.cancel()
        meetingExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, let waiting = self.waiting, waiting.fingerprint == entry.fingerprint,
                  self.shown?.fingerprint != entry.fingerprint else { return }
            if !waiting.interacted { self.record(.ignored, for: waiting, item: waiting.suggestions.first, position: 0) }
            self.waiting = nil
            self.updateGlyph()
        }
    }

    /// Looks ahead to meetings when that's on and Calendar access is granted. `-event` stands in
    /// for the calendar, and `-demo` never reads it.
    func startCalendar() {
        guard settings.calendarContext else { calendar.stop(); return }
        calendar.start(injected: CalendarWatcher.injectedEvent(lead: settings.calendarLead), readCalendar: Self.demoFolder == nil)
    }

    func setCalendarContext(_ on: Bool) {
        settings.calendarContext = on
        startCalendar()
        if !on, pendingAmbient?.meeting != nil {
            signalTask?.cancel()
            pendingAmbient = nil
        }
        if !on, waiting?.meeting != nil {
            waiting = nil
            updateGlyph()
        }
        if !on { ambientSettingsChanged() }
    }

    func setCalendarLead(_ lead: TimeInterval) {
        settings.calendarLead = lead
        calendar.lead = lead
    }

    private static let log = Logger(subsystem: "rs.appea.appears", category: "calendar")

    // MARK: - Pull

    /// The hotkey or a click: read the window now and show what relates, always.
    func pull() async {
        // An ambient result is already waiting: show it.
        if let waiting, waiting.meeting != nil || reader.capture(includeBrowserURL: true)?.snapshot.fingerprint(salt: settings.salt) == waiting.fingerprint {
            selectedIndex = 0
            shown = waiting
            self.waiting = nil
            updateGlyph()
            onShow?(true)
            return
        }
        if let waiting {
            if !waiting.interacted { record(.ignored, for: waiting, item: waiting.suggestions.first, position: 0) }
            self.waiting = nil
            updateGlyph()
        }
        pullError = nil
        skippedReason = nil
        guard modelDownload.phase == .ready else {
            shown = nil
            onShow?(true)
            return
        }
        guard accessibilityTrusted else {
            shown = nil
            onShow?(true)
            return
        }
        guard var captured = reader.capture(includeBrowserURL: true) else {
            pullError = "Nothing to read in this window."
            shown = nil
            onShow?(true)
            return
        }
        if let reason = Exclusions.reason(for: captured, excludedApps: Set(settings.excludedApps), allowUnknownPrivacy: true) {
            skippedReason = "Appears doesn't read this window: \(reason)."
            shown = nil
            onShow?(true)
            return
        }
        isPulling = true
        selectedIndex = 0
        shown = Shown(mode: .pull, bundleID: captured.snapshot.bundleID, appName: captured.snapshot.appName, windowTitle: captured.snapshot.windowTitle,
                      fingerprint: "", suggestions: [])
        onShow?(true)
        defer { isPulling = false }
        // Apps that draw their own text (Google Docs, some Electron apps) need OCR.
        if settings.ocrOnPull, captured.snapshot.visibleText.count + captured.snapshot.focusedText.count < 200,
           let text = await ScreenText.frontmostWindowText() {
            captured.snapshot.visibleText = text
            captured.snapshot.origin = .ocr
        }
        let fingerprint = captured.snapshot.fingerprint(salt: settings.salt)
        do {
            let response = try await engine.related(RecallRequest(context: captured.snapshot, trigger: .pull, limit: Self.contextResultLimit))
            let topic = captured.snapshot.topicFingerprint(salt: settings.salt)
            let eligible = response.suggestions.filter { !policy.isDismissed(itemID: $0.item.id, topic: topic) }
            var entry = Shown(mode: .pull, bundleID: captured.snapshot.bundleID, appName: captured.snapshot.appName, windowTitle: captured.snapshot.windowTitle,
                              fingerprint: fingerprint, topic: topic, suggestions: Array(eligible.prefix(Self.contextResultLimit)),
                              evidenceTerms: response.query.entities + response.query.rareTerms)
            shown = entry
            entry.entryID = await engine.log(journalEntry(entry, dwell: ambientLookups.dwell(), context: captured.snapshot))
            if shown?.fingerprint == fingerprint { shown?.entryID = entry.entryID }
        } catch {
            pullError = error.localizedDescription
            shown = nil
        }
        onShow?(true)
    }

    /// Hovering over the glyph while it shows a result.
    func peek() {
        guard let waiting else { return }
        shown = waiting
        onShow?(false)
    }

    func panelClosed() {
        sourcePreview = nil
        guard let current = shown else { return }
        if current.mode == .ambient, !current.interacted {
            // You looked and moved on.
            record(.ignored, for: current, item: current.suggestions.first, position: 0)
            waiting = nil
        } else if current.mode == .ambient {
            waiting = nil
        }
        updateGlyph()
    }

    // MARK: - Feedback

    func act(_ outcome: Outcome, on suggestion: Suggestion) {
        guard var current = shown else { return }
        let position = current.suggestions.firstIndex(of: suggestion) ?? 0
        current.interacted = true
        shown = current
        record(outcome, for: current, item: suggestion, position: position)
        switch outcome {
        case .opened:
            if let url = suggestion.item.openURL { NSWorkspace.shared.open(url) }
        case .revealed:
            if let url = suggestion.item.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .dismissed, .blocked:
            shown?.suggestions.removeAll { $0 == suggestion }
            selectedIndex = min(selectedIndex, max(visibleSuggestions.count - 1, 0))
        case .muted:
            let bundle = current.bundleID
            if bundle == CalendarEvent.bundleID {
                // "Not before meetings"
                setCalendarContext(false)
            } else if !bundle.isEmpty, !settings.excludedApps.contains(bundle) {
                settings.excludedApps.append(bundle)
            }
            shown?.suggestions.removeAll()
        default:
            break
        }
    }

    /// The visible cards in keyboard order.
    var visibleSuggestions: [Suggestion] {
        shown?.suggestions ?? []
    }

    var selected: Suggestion? {
        let list = visibleSuggestions
        return list.indices.contains(selectedIndex) ? list[selectedIndex] : list.first
    }

    func moveSelection(_ delta: Int) {
        let count = visibleSuggestions.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
        if sourcePreview != nil { sourcePreview = selected?.item.fileURL == nil ? selected : nil }
    }

    private func record(_ outcome: Outcome, for shown: Shown, item: Suggestion?, position: Int) {
        if let item { policy.record(outcome, itemID: item.item.id, topic: shown.topic) }
        guard let entryID = shown.entryID, let item else { return }
        let event = FeedbackEvent(entryID: entryID, itemID: item.item.id, position: position, outcome: outcome)
        Task { await engine.send(.feedback, event) }
    }

    private func journalEntry(_ shown: Shown, dwell: TimeInterval, context: ContextSnapshot) -> JournalEntry {
        #if DEBUG
        let debug = settings.keepDebugContext ? String((context.windowTitle + "\n" + context.focusedText + "\n" + context.visibleText).prefix(600)) : nil
        #else
        let debug: String? = nil
        #endif
        return JournalEntry(
            mode: shown.mode, bundleID: context.bundleID, fingerprint: shown.fingerprint, dwellSeconds: dwell,
            suggestions: shown.suggestions.map(JournalEntry.Shown.init), debugContext: debug
        )
    }

    // MARK: - Settings

    func scanNow() async {
        guard !isRequestingScan else { return }
        isRequestingScan = true
        scanRequestMessage = nil
        scanRequestError = nil
        scanRequestedAfter = status?.lastScanCompletedAt
        defer { isRequestingScan = false }
        // Apply any source changes before asking the engine to scan them.
        await sourcesUpdate?.value
        do {
            _ = try await engine.call(.rescan, EngineClient.Empty(), as: EngineClient.Empty.self)
            awaitingScanCompletion = true
            scanRequestMessage = "Scanning enabled sources… Existing results remain searchable."
            await refreshStatus()
        } catch {
            scanRequestError = "Couldn’t request a scan. Try again, or reopen Appears."
        }
    }

    func sourcesChanged() {
        sourcePreview = nil
        contacts.start(enabled: settings.sources.messages && Self.demoFolder == nil)
        dwellTask?.cancel()
        signalTask?.cancel()
        pendingAmbient = nil
        shown?.suggestions.removeAll { !mayShow($0.item) }
        waiting?.suggestions.removeAll { !mayShow($0.item) }
        selectedIndex = min(selectedIndex, max(visibleSuggestions.count - 1, 0))
        let previous = sourcesUpdate
        sourcesUpdate = Task {
            await previous?.value
            await engine.send(.settings, engineSources)
            ambientSettingsChanged()
        }
    }

    func mayShow(_ item: Item) -> Bool {
        let sources = engineSources
        if sources.excludedKinds.contains(item.kind) { return false }
        if item.source == .notes, !sources.notes { return false }
        if item.source == .messages, !sources.messages { return false }
        return !FileScanner(settings: sources).isExcluded(item.fileURL?.path ?? item.path)
    }

    /// `-ask`: wait for the engine to be ready and idle, then ask with scripted text.
    private func scriptedPull(_ text: String) async {
        while true {
            let status = await engine.status()
            NSLog("Appears scripted ask: waiting (ready %@, phase %@, waiting %d)", String(describing: status?.ready), status?.progress.phase.rawValue ?? "nil", status?.counts.waiting ?? -1)
            if let status, status.ready, status.progress.phase == .idle, status.counts.waiting == 0 { break }
            try? await Task.sleep(for: .seconds(5))
        }
        let context = ContextSnapshot(appName: "Mail", bundleID: "com.apple.mail", windowTitle: "Scripted", focusedText: text, origin: .text)
        isPulling = true
        selectedIndex = 0
        shown = Shown(mode: .pull, appName: "Mail", windowTitle: "Scripted", fingerprint: "", suggestions: [])
        onShow?(true)
        let response = try? await engine.related(RecallRequest(context: context, trigger: .pull, limit: Self.contextResultLimit))
        let suggestions = response?.suggestions ?? []
        shown = Shown(mode: .pull, appName: "Mail", windowTitle: "Scripted", fingerprint: context.fingerprint(salt: settings.salt),
                      suggestions: Array(suggestions.prefix(Self.contextResultLimit)), evidenceTerms: (response?.query.entities ?? []) + (response?.query.rareTerms ?? []))
        isPulling = false
        onShow?(true)
        NSLog("Appears scripted ask: %@", (shown?.suggestions ?? []).map { "\($0.item.title) (\(String(format: "%.2f", $0.confidence)))" }.joined(separator: ", "))
    }

    func pause(for interval: TimeInterval?) {
        settings.pausedUntil = interval.map { Date().addingTimeInterval($0) }
        dwellTask?.cancel()
        signalTask?.cancel()
        pendingAmbient = nil
        waiting = nil
        if interval == nil { contextChanged() }
        updateGlyph()
    }

    /// Pause until 8 AM tomorrow.
    func pauseUntilTomorrow() {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!.addingTimeInterval(8 * 3_600)
        pause(for: tomorrow.timeIntervalSinceNow)
    }

    func setAmbientMode(_ mode: AmbientMode) {
        settings.ambientMode = mode
        dwellTask?.cancel()
        signalTask?.cancel()
        pendingAmbient = nil
        waiting = nil
        ambientLookups.invalidate()
        if mode != .off { contextChanged() }
        updateGlyph()
    }

    func ambientSettingsChanged() {
        ambientLookups.invalidate()
        contextChanged()
    }


    /// For the snapshot tool: show these suggestions without the engine.
    func showForSnapshot(_ shown: Shown?, status: EngineStatus?, trusted: Bool = true) {
        self.shown = shown
        selectedIndex = 0
        self.status = status
        modelDownload = ModelDownloadStatus(phase: .ready)
        accessibilityTrusted = trusted
    }

    func showDownloadForSnapshot(_ download: ModelDownloadStatus) { modelDownload = download }
}
