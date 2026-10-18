import AppKit
import AppearsCore
import QuickLookUI
import SwiftUI

/// The menu bar item and the panel that hangs from it.
///
/// - Click: pull (what do I already have about this?), or show what's waiting.
/// - Right-click: pause, settings, quit.
@MainActor
final class StatusController: NSObject, NSMenuItemValidation {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel: ResultsPanel
    private var pullTask: Task<Void, Never>?
    private var pullRevision = 0
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    private var glyphAnimator: StatusGlyphAnimator?
    private let toast = MatchToastController()
    private var lastWaitingAt: Date?
    private var lastWaitingItemID: Int64?
    private var lastAlertStyle: MatchAlertStyle?
    var isToastVisible: Bool { toast.isVisible }
    private let performPull: @MainActor () async -> Void
    var isVisible: Bool { panel.isVisible }
    var openSettings: (() -> Void)?
    var openSources: (() -> Void)?
    var openSearch: (() -> Void)?
    var willShow: (() -> Void)?

    init(model: AppModel, pull: (@MainActor () async -> Void)? = nil) {
        self.model = model
        performPull = pull ?? { await model.pull() }
        panel = ResultsPanel()
        super.init()
        panel.contentView = NSHostingView(rootView: PanelView(model: model, close: { [weak self] in self?.close() }, openSettings: { [weak self] in
            self?.close(); self?.openSettings?()
        }, openSources: { [weak self] in
            self?.close(); self?.openSources?()
        }, openSearch: { [weak self] in self?.openSearch?() }, resize: { [weak self] size in
            guard let self, self.panel.isVisible else { return }
            self.position(contentSize: size)
        }))
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        if let button = item.button {
            glyphAnimator = StatusGlyphAnimator(button: button)
            glyphAnimator?.update(model.glyph, style: model.settings.matchAlertStyle)
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        model.onShow = { [weak self] makeKey in self?.show(makeKey: makeKey) }
        updateAlert()
        observeAlert()
    }

    private func observeAlert() {
        withObservationTracking {
            _ = model.glyph
            _ = model.waiting
            _ = model.settings.matchAlertStyle
            _ = model.settings.ambientMode
            _ = model.settings.pausedUntil
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.updateAlert()
                self.observeAlert()
            }
        }
    }

    private func updateAlert() {
        let style = model.settings.matchAlertStyle
        glyphAnimator?.update(model.glyph, style: style)
        let waiting = model.waiting
        let isNew = waiting?.at != lastWaitingAt
        if isNew || waiting?.suggestions.first?.id != lastWaitingItemID || style != lastAlertStyle
            || model.glyph != .found || model.settings.ambientMode != .on || model.settings.isPaused {
            toast.dismiss()
        }
        lastWaitingAt = waiting?.at
        lastWaitingItemID = waiting?.suggestions.first?.id
        lastAlertStyle = style
        // Changing preferences never replays an old discovery. Only a newly accepted
        // ambient result can show a toast; pull/search and log-only mode cannot.
        guard isNew, style == .toast, model.glyph == .found, !panel.isVisible,
              model.settings.ambientMode == .on, !model.settings.isPaused,
              let waiting, waiting.mode == .ambient else { return }
        toast.show(waiting, contacts: model.contacts, screen: item.button?.window?.screen) { [weak self] in
            guard let self else { return }
            self.toast.dismiss()
            self.model.openWaitingMatch(at: waiting.at)
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            showMenu()
            return
        }
        togglePull()
    }

    func togglePull() {
        if panel.isVisible || pullTask != nil { close() } else { requestPull() }
    }

    private func requestPull() {
        pullTask?.cancel()
        pullRevision += 1
        let revision = pullRevision
        pullTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.performPull()
            if self.pullRevision == revision { self.pullTask = nil }
        }
    }

    // MARK: - The panel

    private func show(makeKey: Bool) {
        guard !Task.isCancelled else { return }
        toast.dismiss()
        willShow?()
        position()
        if makeKey {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.dismissIfOutside()
                }
            }
            localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                self?.dismissIfOutside()
                return event
            }
        }
    }

    private func dismissIfOutside() {
        guard panel.isVisible, !panel.frame.contains(NSEvent.mouseLocation) else { return }
        // The status button owns the click's toggle. Treating its mouse-down as an
        // outside dismissal would close and then reopen on the same mouse-up.
        if let button = item.button, let window = button.window,
           window.convertToScreen(button.convert(button.bounds, to: nil)).contains(NSEvent.mouseLocation) { return }
        close()
    }

    func close() {
        toast.dismiss()
        pullRevision += 1
        pullTask?.cancel()
        pullTask = nil
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil) }
        panel.orderOut(nil)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        clickMonitor = nil
        localClickMonitor = nil
        model.panelClosed()
    }

    private func position(contentSize: CGSize? = nil) {
        guard let button = item.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let size = contentSize ?? panel.contentView?.fittingSize ?? NSSize(width: 400, height: 200)
        panel.setContentSize(NSSize(width: 400, height: max(size.height, 120)))
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = anchor.midX - 400 + 28
        x = min(max(x, screen.minX + 8), screen.maxX - 408)
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: anchor.minY - 6))
    }

    // MARK: - Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:
            if model.sourcePreview != nil { model.sourcePreview = nil } else { close() }
            return true
        case 125: model.moveSelection(1); return true  // ↓
        case 126: model.moveSelection(-1); return true  // ↑
        case 36, 76:  // Return
            if let selected = model.sourcePreview ?? model.selected {
                model.act(event.modifierFlags.contains(.command) ? .revealed : .opened, on: selected)
                close()
            }
            return true
        case 49: quickLook(); return true  // Space
        case 51:  // Delete
            if let selected = model.selected { model.act(.dismissed, on: selected) }
            return true
        default:
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if modifiers == [.command, .option], event.charactersIgnoringModifiers == "c" { copyLine(); return true }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "," { openSettings?(); return true }
            return false
        }
    }

    /// ⌥⌘C: copy the selected result's matched line, then close, so ⌘V lands in the app you're
    /// in. (⌘C is left free.)
    func copyLine() {
        guard let selected = model.sourcePreview ?? model.selected, let line = selected.line else { return }
        line.copyToPasteboard()
        model.act(.copiedLine, on: selected)
        close()
    }

    func quickLook() {
        guard let selected = model.selected else { return }
        guard let url = selected.item.fileURL else {
            model.sourcePreview = model.sourcePreview == nil ? selected : nil
            if model.sourcePreview != nil { model.act(.previewed, on: selected) }
            return
        }
        model.act(.previewed, on: selected)
        panel.previewURL = url
        let preview = QLPreviewPanel.shared()!
        if preview.isVisible { preview.orderOut(nil) } else { preview.makeKeyAndOrderFront(nil) }
    }

    // MARK: - Menu

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Search Appears…", action: #selector(searchFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "What do I already have about this?", action: #selector(pullFromMenu), keyEquivalent: "").target = self
        menu.addItem(.separator())
        if model.settings.isPaused {
            menu.addItem(withTitle: "Resume", action: #selector(resume), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: "Pause for an hour", action: #selector(pauseHour), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Pause until tomorrow", action: #selector(pauseDay), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        if model.modelDownload.phase != .ready {
            let state = model.modelDownload
            let title = state.phase == .failed ? "Model download needs attention" : "Preparing model · \(Int(state.fraction * 100))%"
            menu.addItem(withTitle: title, action: nil, keyEquivalent: "").isEnabled = false
        } else if let status = model.status {
            menu.addItem(withTitle: Self.indexLine(status), action: nil, keyEquivalent: "").isEnabled = false
        }
        menu.addItem(withTitle: "Index & Sources…", action: #selector(sourcesFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(settingsFromMenu), keyEquivalent: ",").target = self
        let updateTitle = model.updater.availableVersion.map { "Version \($0) Available…" } ?? "Check for Updates…"
        let updateItem = menu.addItem(withTitle: updateTitle, action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        updateItem.isEnabled = model.updater.canCheck
        menu.addItem(withTitle: "Quit Appears", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    /// "7,803 of 10,612 indexed · indexing…" while anything is waiting, else the total.
    static func indexLine(_ status: EngineStatus) -> String {
        if status.isScanning { return "Checking enabled sources…" }
        if status.error != nil { return "Index needs attention" }
        if !status.ready { return "Starting the search engine…" }
        let counts = status.counts
        guard counts.waiting > 0 else { return "\(counts.indexedTotal.formatted()) things indexed" }
        let total = counts.indexedTotal + counts.waiting
        let state: String = switch status.progress.phase {
        case .indexing: "indexing…"
        case .scanning: "looking for files…"
        case .paused: "paused: \(status.progress.pausedReason ?? "waiting")"
        case .idle: "waiting to continue"
        }
        return "\(counts.indexedTotal.formatted()) of \(total.formatted()) indexed · \(state)"
    }

    @objc private func pullFromMenu() { requestPull() }
    @objc private func searchFromMenu() { openSearch?() }
    @objc private func pauseHour() { model.pause(for: 3_600) }
    @objc private func pauseDay() { model.pauseUntilTomorrow() }
    @objc private func resume() { model.pause(for: nil) }
    @objc private func settingsFromMenu() { openSettings?() }
    @objc private func sourcesFromMenu() { openSources?() }
    @objc private func checkForUpdates() { model.updater.checkNow() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(checkForUpdates) || model.updater.canCheck
    }
}

/// A panel that can take keys without activating Appears, so the app you're in stays
/// active and your cursor stays where it was.
final class ResultsPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?
    var previewURL: URL?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered, defer: true
        )
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isMovable = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) != true { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        _ = keyHandler?(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!)
    }

    // Quick Look
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
    }
}

extension ResultsPanel: @preconcurrency QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { previewURL as NSURL? }
}
