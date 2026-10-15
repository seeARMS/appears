import AppKit
import AppearsCore
import QuickLookUI
import SwiftUI

/// The menu bar item and the panel that hangs from it.
///
/// - Click: pull (what do I already have about this?), or show what's waiting.
/// - Hover while the glyph has something: peek, without taking focus.
/// - Right-click: pause, settings, quit.
@MainActor
final class StatusController: NSObject {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel: ResultsPanel
    private var hoverCloseTask: Task<Void, Never>?
    private var clickMonitor: Any?
    var openSettings: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        panel = ResultsPanel()
        super.init()
        panel.contentView = NSHostingView(rootView: PanelView(model: model, close: { [weak self] in self?.close() }))
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        if let button = item.button {
            button.image = GlyphImage.image(for: model.glyph)
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        model.onShow = { [weak self] makeKey in self?.show(makeKey: makeKey) }
        observeGlyph()
    }

    private func observeGlyph() {
        withObservationTracking { _ = model.glyph } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.item.button?.image = GlyphImage.image(for: self.model.glyph)
                self.observeGlyph()
            }
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            showMenu()
            return
        }
        if panel.isVisible, panel.isKeyWindow {
            close()
        } else {
            Task { await model.pull() }
        }
    }

    func togglePull() {
        if panel.isVisible { close() } else { Task { await model.pull() } }
    }

    // MARK: - Hover

    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) {
        hoverCloseTask?.cancel()
        if model.glyph == .found, !panel.isVisible { model.peek() }
    }

    @objc(mouseExited:) func mouseExited(with event: NSEvent) {
        guard panel.isVisible, !panel.isKeyWindow else { return }
        hoverCloseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.8))
            guard let self, !Task.isCancelled else { return }
            if !self.panel.frame.contains(NSEvent.mouseLocation), !self.panel.isKeyWindow { self.close() }
        }
    }

    // MARK: - The panel

    private func show(makeKey: Bool) {
        position()
        if makeKey {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.panel.isVisible, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                    self.close()
                }
            }
        }
    }

    func close() {
        guard panel.isVisible else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil) }
        panel.orderOut(nil)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        model.panelClosed()
    }

    private func position() {
        guard let button = item.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.contentView?.fittingSize ?? NSSize(width: 400, height: 200)
        panel.setContentSize(NSSize(width: 400, height: max(size.height, 120)))
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = anchor.midX - 400 + 28
        x = min(max(x, screen.minX + 8), screen.maxX - 408)
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: anchor.minY - 6))
    }

    // MARK: - Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: close(); return true  // Esc
        case 125: model.moveSelection(1); return true  // ↓
        case 126: model.moveSelection(-1); return true  // ↑
        case 36, 76:  // Return
            if let selected = model.selected {
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
        guard let selected = model.selected, let line = selected.line else { return }
        line.copyToPasteboard()
        model.act(.copiedLine, on: selected)
        close()
    }

    func quickLook() {
        guard let selected = model.selected, selected.item.source == .file else { return }
        model.act(.previewed, on: selected)
        panel.previewURL = URL(filePath: selected.item.path)
        let preview = QLPreviewPanel.shared()!
        if preview.isVisible { preview.orderOut(nil) } else { preview.makeKeyAndOrderFront(nil) }
    }

    // MARK: - Menu

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "What do I already have about this?", action: #selector(pullFromMenu), keyEquivalent: "").target = self
        menu.addItem(.separator())
        if model.settings.isPaused {
            menu.addItem(withTitle: "Resume", action: #selector(resume), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: "Pause for an hour", action: #selector(pauseHour), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Pause until tomorrow", action: #selector(pauseDay), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        if let status = model.status {
            menu.addItem(withTitle: Self.indexLine(status), action: nil, keyEquivalent: "").isEnabled = false
        }
        menu.addItem(withTitle: "Settings…", action: #selector(settingsFromMenu), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit Appears", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    /// "7,803 of 10,612 indexed · indexing…" while anything is waiting, else the total.
    static func indexLine(_ status: EngineStatus) -> String {
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

    @objc private func pullFromMenu() { Task { await model.pull() } }
    @objc private func pauseHour() { model.pause(for: 3_600) }
    @objc private func pauseDay() {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!.addingTimeInterval(8 * 3_600)
        model.pause(for: tomorrow.timeIntervalSinceNow)
    }
    @objc private func resume() { model.pause(for: nil) }
    @objc private func settingsFromMenu() { openSettings?() }
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
