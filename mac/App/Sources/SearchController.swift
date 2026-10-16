import AppKit
import QuickLookUI
import SwiftUI

/// Explicit search takes keyboard focus; the ambient panel remains nonactivating.
@MainActor
final class SearchController: NSObject, NSWindowDelegate {
    let model: SearchModel
    private let panel = SearchPanel()
    private var previousApp: NSRunningApplication?
    var openSettings: (() -> Void)?
    var willShow: (() -> Void)?

    init(app: AppModel) {
        model = SearchModel(app: app)
        super.init()
        panel.delegate = self
        panel.handleKey = { [weak self] in self?.handleKey($0) ?? false }
        panel.contentView = NSHostingView(rootView: SearchView(
            model: model,
            close: { [weak self] in self?.close() },
            finish: { [weak self] in self?.close(restoreFocus: false) },
            openSettings: { [weak self] in self?.settings() },
            resize: { [weak self] in self?.resize($0) }
        ))
    }

    func toggle() { if panel.isVisible { close() } else { show() } }

    func show() {
        willShow?()
        if !panel.isVisible, let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        model.begin()
        let frame = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? .zero
        panel.setContentSize(NSSize(width: 640, height: model.hasQuery ? 455 : 253))
        // Anchor the search bar in the upper third; results grow down from it.
        panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - frame.height * 0.22))
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        focusField(in: panel.contentView)
    }

    func close(restoreFocus: Bool = true) {
        guard panel.isVisible else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared()?.orderOut(nil) }
        panel.orderOut(nil)
        model.clear()
        if restoreFocus, NSApp.isActive { previousApp?.activate() }
        previousApp = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !self.panel.isKeyWindow else { return }
            if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { return }
            self.close(restoreFocus: false)
        }
    }

    private func resize(_ size: CGSize) {
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.setContentSize(size)
        if panel.isVisible { panel.setFrameTopLeftPoint(topLeft) }
    }

    private func focusField(in view: NSView?) {
        guard let view else { return }
        if let field = view as? NSTextField { panel.makeFirstResponder(field); return }
        for child in view.subviews { focusField(in: child) }
    }

    private func settings() { close(restoreFocus: false); openSettings?() }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers == .command {
            switch event.charactersIgnoringModifiers {
            case "y": quickLook(); return true
            case ",": settings(); return true
            default: break
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                if let selected = model.selected, model.open(selected, reveal: true) { close(restoreFocus: false) }
                return true
            }
        }
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 53:
            if model.sourcePreview != nil { model.sourcePreview = nil } else { close() }
            return true
        case 125: model.moveSelection(1); return true
        case 126: model.moveSelection(-1); return true
        case 36, 76:
            if let selected = model.selected, model.open(selected, reveal: modifiers.contains(.command)) { close(restoreFocus: false) }
            return true
        default: return false
        }
    }

    private func quickLook() {
        guard !model.isSearching else { return }
        if model.selected?.item.fileURL == nil { model.toggleSourcePreview(); return }
        guard let url = model.selected?.item.fileURL else { return }
        panel.previewURL = url
        let preview = QLPreviewPanel.shared()!
        if preview.isVisible { preview.orderOut(nil); panel.makeKeyAndOrderFront(nil) }
        else { preview.makeKeyAndOrderFront(nil) }
    }
}

private final class SearchPanel: NSPanel {
    var handleKey: ((NSEvent) -> Bool)?
    var previewURL: URL?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: true)
        becomesKeyOnlyIfNeeded = false
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        title = "Search Appears"
        setAccessibilityLabel("Search Appears")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if handleKey?(event) != true { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), handleKey?(event) == true { return true }
        // An accessory app has no Edit menu to dispatch these standard field-editor keys.
        if event.modifierFlags.intersection([.command, .option, .control]) == .command,
           let editor = firstResponder as? NSTextView {
            switch event.charactersIgnoringModifiers {
            case "a": editor.selectAll(nil)
            case "c": editor.copy(nil)
            case "v": editor.paste(nil)
            case "x": editor.cut(nil)
            case "z":
                if event.modifierFlags.contains(.shift) { editor.undoManager?.redo() }
                else { editor.undoManager?.undo() }
            default: return super.performKeyEquivalent(with: event)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = self }
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil }
    }
}

extension SearchPanel: @preconcurrency QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { previewURL as NSURL? }
}
