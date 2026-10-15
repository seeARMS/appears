import AppKit
import AppearsContext
import AppearsCore
import Foundation
import os

/// Everything the menu bar item and the panel show, and the loop that decides when to look.
///
/// The loop: the Accessibility observer reports a change → wait for it to settle → note the
/// "topic" (app, window, document, URL) and when it started → after you've dwelled long
/// enough, ask the engine (ambient) → if the answer is confident and the policy allows,
/// change the glyph. Nothing else happens until you look.
@MainActor @Observable
final class AppModel {
    var settings = AppSettings()
    let engine = EngineClient()
    @ObservationIgnored let reader = ContextReader()
    @ObservationIgnored let calendar = CalendarWatcher()
    @ObservationIgnored private var policy = SurfacePolicy()

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
        var suggestions: [Suggestion]
        /// Suggestions below the bar, shown only on request (pull).
        var weaker: [Suggestion]
        var interacted = false
        var at = Date()
        /// Set when this is for an upcoming meeting rather than a window. In memory only.
        var meeting: CalendarEvent?
    }

    private(set) var glyph: Glyph = .idle
    private(set) var status: EngineStatus?
    /// What the panel shows.
    private(set) var shown: Shown?
    /// An ambient result waiting behind the glyph.
    private(set) var waiting: Shown?
    private(set) var isPulling = false
    /// The highlighted card, for the keyboard.
    var selectedIndex = 0
    var showWeaker = false
    private(set) var pullError: String?
    private(set) var accessibilityTrusted = ContextReader.isTrusted
    /// Why the last context wasn't used, for the panel's footer ("password field").
    private(set) var skippedReason: String?

    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var dwellTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var topic: String?
    @ObservationIgnored private var topicSince = Date()
    @ObservationIgnored private var meetingExpiry: Task<Void, Never>?

    /// Called when the panel should open or update (the status item owns the panel).
    @ObservationIgnored var onShow: ((_ makeKey: Bool) -> Void)?

    static let strongConfidence = 0.15

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

    /// The source settings sent to the engine (demo mode replaces home and skips Notes).
    var engineSources: SourceSettings {
        var sources = settings.sources
        if let demo = Self.demoFolder {
            sources.homeOverride = demo
            sources.notes = false
        }
        return sources
    }

    func start() {
        policy = SurfacePolicy(settings: settings.policySettings)
        reader.onChange = { [weak self] in self?.contextChanged() }
        reader.start()
        calendar.lead = settings.calendarLead
        calendar.onDue = { [weak self] event in Task { await self?.meetingCheck(event) } }
        startCalendar()
        statusTask = Task { [weak self] in
            // Settings first, so the engine loads with them.
            if let self { await self.engine.send(.settings, self.engineSources) }
            if let text = Self.scriptedAsk {
                Task { [weak self] in await self?.scriptedPull(text) }
            }
            while !Task.isCancelled {
                await self?.refreshStatus()
                let busy = self?.status.map { $0.progress.phase != .idle || !$0.ready } ?? true
                try? await Task.sleep(for: .seconds(busy ? 3 : 20))
            }
        }
        contextChanged()
    }

    func refreshStatus() async {
        accessibilityTrusted = ContextReader.isTrusted
        if accessibilityTrusted { reader.start() }
        // Calendar access granted in System Settings since launch.
        if settings.calendarContext, !calendar.isRunning, Self.demoFolder == nil, CalendarWatcher.access == .granted { startCalendar() }
        status = await engine.status()
        updateGlyph()
    }

    private func updateGlyph() {
        if !accessibilityTrusted {
            glyph = .needsSetup
        } else if settings.isPaused {
            glyph = .paused
        } else if waiting != nil {
            glyph = .found
        } else if let status, status.ready, status.progress.phase == .idle {
            glyph = .idle
        } else {
            glyph = .working
        }
    }

    // MARK: - The context loop

    private func contextChanged() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.settled()
        }
    }

    /// The context has stopped changing. If the topic is new, the dwell clock restarts.
    private func settled() {
        guard settings.onboarded, !settings.isPaused, let captured = reader.capture(includeBrowserURL: false) else { return }
        let snapshot = captured.snapshot
        if let path = snapshot.documentPath {
            // Files you have open count as recently used.
            Task { await engine.send(.touch, path) }
        }
        guard snapshot.topic != topic else { return }
        topic = snapshot.topic
        topicSince = Date()
        // A suggestion for the old context is stale now. One for a meeting waits for the meeting.
        if let waiting, waiting.meeting == nil {
            if !waiting.interacted { record(.ignored, for: waiting, item: waiting.suggestions.first, position: 0) }
            self.waiting = nil
        }
        updateGlyph()
        scheduleAmbient()
    }

    private func scheduleAmbient() {
        dwellTask?.cancel()
        guard settings.ambientMode != .off else { return }
        let dwell = settings.dwell
        dwellTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(dwell))
            guard !Task.isCancelled else { return }
            await self?.ambientCheck()
        }
    }

    /// You've stayed in one context long enough: look, quietly.
    private func ambientCheck() async {
        guard settings.ambientMode != .off, !settings.isPaused, accessibilityTrusted, waiting?.meeting == nil,
              let captured = reader.capture(includeBrowserURL: true) else { return }
        if let reason = Exclusions.reason(for: captured, excludedApps: Set(settings.excludedApps), allowUnknownPrivacy: settings.ambientInSafari) {
            skippedReason = reason
            return
        }
        guard captured.snapshot.characterCount >= 80 else { return }
        let fingerprint = captured.snapshot.fingerprint(salt: settings.salt)
        policy.settings = settings.policySettings
        let dwell = Date().timeIntervalSince(topicSince)
        guard policy.mayLook(dwell: dwell, fingerprint: fingerprint) == .show else { return }
        guard let response = try? await engine.related(RecallRequest(context: captured.snapshot, trigger: .ambient, limit: 3)) else { return }
        // The context may have moved on while the engine worked.
        guard captured.snapshot.topic == topic else { return }
        let confident = response.suggestions.filter { policy.isConfident($0.confidence) }
        guard !confident.isEmpty else { return }

        let mode: JournalEntry.Mode = settings.ambientMode == .on ? .ambient : .shadow
        var entry = Shown(
            mode: mode, bundleID: captured.snapshot.bundleID, appName: captured.snapshot.appName, windowTitle: captured.snapshot.windowTitle,
            fingerprint: fingerprint, suggestions: confident, weaker: []
        )
        entry.entryID = await engine.log(journalEntry(entry, dwell: dwell, context: captured.snapshot))
        policy.didSurface(fingerprint: fingerprint)
        if mode == .ambient {
            waiting = entry
            updateGlyph()
        }
    }

    // MARK: - Meetings

    /// A meeting is coming up: look for what you already have about it, quietly. The same
    /// policy as a window (the threshold, the hourly budget, the backoff), minus the dwell: the
    /// lead time is the moment. Its suggestion waits behind the glyph until shortly after the
    /// meeting starts, whatever window you're in.
    private func meetingCheck(_ event: CalendarEvent) async {
        guard settings.calendarContext, settings.ambientMode != .off, !settings.isPaused,
              settings.onboarded || CalendarWatcher.isInjecting else { return }
        let snapshot = event.snapshot()
        let fingerprint = snapshot.fingerprint(salt: settings.salt)
        policy.settings = settings.policySettings
        let decision = policy.mayLook(dwell: .infinity, fingerprint: fingerprint)
        guard decision == .show else {
            if case .wait(let reason) = decision { Self.log.info("Meeting coming up; not looking (\(reason, privacy: .public))") }
            return
        }
        guard let response = try? await engine.related(RecallRequest(context: snapshot, trigger: .ambient, limit: 3)) else { return }
        let confident = response.suggestions.filter { policy.isConfident($0.confidence) }
        Self.log.info("Looked ahead to a meeting: top confidence \(response.confidence, format: .fixed(precision: 2), privacy: .public), \(confident.count, privacy: .public) confident")
        guard !confident.isEmpty, event.start > Date() else { return }

        let mode: JournalEntry.Mode = settings.ambientMode == .on ? .ambient : .shadow
        var entry = Shown(
            mode: mode, bundleID: CalendarEvent.bundleID, appName: CalendarEvent.appName, windowTitle: event.title,
            fingerprint: fingerprint, suggestions: confident, weaker: [], meeting: event
        )
        entry.entryID = await engine.log(journalEntry(entry, dwell: 0, context: snapshot))
        policy.didSurface(fingerprint: fingerprint)
        guard mode == .ambient else { return }
        if let waiting, !waiting.interacted { record(.ignored, for: waiting, item: waiting.suggestions.first, position: 0) }
        waiting = entry
        updateGlyph()
        Self.log.info("Something for the meeting is waiting behind the glyph (\(String(describing: self.glyph), privacy: .public))")
        expireMeeting(entry, at: min(event.end, event.start.addingTimeInterval(10 * 60)))
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
        if !on, waiting?.meeting != nil {
            waiting = nil
            updateGlyph()
        }
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
        if let waiting {
            selectedIndex = 0
            shown = waiting
            self.waiting = nil
            updateGlyph()
            onShow?(true)
            return
        }
        pullError = nil
        skippedReason = nil
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
        showWeaker = false
        shown = Shown(mode: .pull, bundleID: captured.snapshot.bundleID, appName: captured.snapshot.appName, windowTitle: captured.snapshot.windowTitle,
                      fingerprint: "", suggestions: [], weaker: [])
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
            let response = try await engine.related(RecallRequest(context: captured.snapshot, trigger: .pull, limit: 6))
            let strong = response.suggestions.filter { $0.confidence >= Self.strongConfidence }.prefix(3)
            let weaker = response.suggestions.filter { !strong.contains($0) }.prefix(3)
            var entry = Shown(mode: .pull, bundleID: captured.snapshot.bundleID, appName: captured.snapshot.appName, windowTitle: captured.snapshot.windowTitle,
                              fingerprint: fingerprint, suggestions: Array(strong), weaker: Array(weaker))
            shown = entry
            entry.entryID = await engine.log(journalEntry(entry, dwell: Date().timeIntervalSince(topicSince), context: captured.snapshot))
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
        let position = (current.suggestions + current.weaker).firstIndex(of: suggestion) ?? 0
        current.interacted = true
        shown = current
        record(outcome, for: current, item: suggestion, position: position)
        switch outcome {
        case .opened:
            if let url = suggestion.item.openURL { NSWorkspace.shared.open(url) }
        case .revealed:
            if suggestion.item.source == .file { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: suggestion.item.path)]) }
        case .dismissed, .blocked:
            shown?.suggestions.removeAll { $0 == suggestion }
            shown?.weaker.removeAll { $0 == suggestion }
        case .muted:
            let bundle = current.bundleID
            if bundle == CalendarEvent.bundleID {
                // "Not before meetings"
                setCalendarContext(false)
            } else if !bundle.isEmpty, !settings.excludedApps.contains(bundle) {
                settings.excludedApps.append(bundle)
            }
            shown?.suggestions.removeAll()
            shown?.weaker.removeAll()
        default:
            break
        }
    }

    /// The visible cards in keyboard order.
    var visibleSuggestions: [Suggestion] {
        guard let shown else { return [] }
        return shown.suggestions + (showWeaker || shown.suggestions.isEmpty ? shown.weaker : [])
    }

    var selected: Suggestion? {
        let list = visibleSuggestions
        return list.indices.contains(selectedIndex) ? list[selectedIndex] : list.first
    }

    func moveSelection(_ delta: Int) {
        let count = visibleSuggestions.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func record(_ outcome: Outcome, for shown: Shown, item: Suggestion?, position: Int) {
        if shown.mode == .ambient { policy.record(outcome) }
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
            suggestions: (shown.suggestions + shown.weaker).map(JournalEntry.Shown.init), debugContext: debug
        )
    }

    // MARK: - Settings

    func sourcesChanged() {
        Task { await engine.send(.settings, engineSources) }
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
        shown = Shown(mode: .pull, appName: "Mail", windowTitle: "Scripted", fingerprint: "", suggestions: [], weaker: [])
        onShow?(true)
        let response = try? await engine.related(RecallRequest(context: context, trigger: .pull, limit: 6))
        let suggestions = response?.suggestions ?? []
        let strong = suggestions.filter { $0.confidence >= Self.strongConfidence }.prefix(3)
        shown = Shown(mode: .pull, appName: "Mail", windowTitle: "Scripted", fingerprint: context.fingerprint(salt: settings.salt),
                      suggestions: Array(strong), weaker: Array(suggestions.filter { !strong.contains($0) }.prefix(3)))
        isPulling = false
        onShow?(true)
        NSLog("Appears scripted ask: %@", (shown?.suggestions ?? []).map { "\($0.item.title) (\(String(format: "%.2f", $0.confidence)))" }.joined(separator: ", "))
    }

    func pause(for interval: TimeInterval?) {
        settings.pausedUntil = interval.map { Date().addingTimeInterval($0) }
        waiting = nil
        updateGlyph()
    }

    func setAmbientMode(_ mode: AmbientMode) {
        settings.ambientMode = mode
        if mode == .off { dwellTask?.cancel(); waiting = nil }
        updateGlyph()
    }


    /// For the snapshot tool: show these suggestions without the engine.
    func showForSnapshot(_ shown: Shown?, status: EngineStatus?, trusted: Bool = true) {
        self.shown = shown
        self.status = status
        accessibilityTrusted = trusted
    }
}
