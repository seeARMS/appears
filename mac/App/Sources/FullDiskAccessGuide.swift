import AppKit
import SwiftUI

/// System Settings doesn't list an app under Full Disk Access until you add it, and macOS
/// shows the Screen Recording prompt only the first time an app asks. So for both, this opens
/// the pane and floats a small card beside it with Appears' icon to drag into the list. The card
/// closes itself once access is granted, or when you close it.
@MainActor
enum FullDiskAccessGuide {
    private static var panel: NSPanel?
    private static var timer: Timer?
    /// Whether the permission the card is about has been granted.
    private static var check: () -> Bool = { isGranted }

    static let screenRecordingURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Whether this process has Full Disk Access: it can open something only Full Disk Access
    /// opens. Several probes, since any one of them may be missing on a given Mac. (macOS
    /// applies a new grant only after the app relaunches; System Settings offers to do that.)
    static var isGranted: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let files = [
            home + "/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite",
            home + "/Library/Messages/chat.db",
            home + "/Library/Safari/Bookmarks.plist",
        ]
        for path in files where FileManager.default.fileExists(atPath: path) {
            if let handle = FileHandle(forReadingAtPath: path) {
                try? handle.close()
                return true
            }
        }
        for folder in [home + "/Library/Safari", home + "/Library/Mail"] {
            if (try? FileManager.default.contentsOfDirectory(atPath: folder)) != nil { return true }
        }
        return false
    }

    static func open() {
        NSWorkspace.shared.open(settingsURL)
        guard !isGranted else { return }
        check = { isGranted }
        show()
    }

    /// Screen Recording: the system prompt the first time, the pane and the card after that.
    static func openScreenRecording() {
        if CGPreflightScreenCaptureAccess() { return }
        // Shows the system prompt (and adds Appears to the list) only the first time; after
        // that it returns false without showing anything.
        if CGRequestScreenCaptureAccess() { return }
        NSWorkspace.shared.open(screenRecordingURL)
        check = { CGPreflightScreenCaptureAccess() }
        show()
    }

    private static func show() {
        close()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: FullDiskAccessCard(close: { close() }))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        self.panel = panel
        // System Settings takes a moment to open and size its window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            position(panel)
            panel.orderFrontRegardless()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                if check() { close() }
            }
        }
    }

    static func close() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// Beside System Settings' window (left of it if there's room, else below), or at the
    /// bottom of the screen if it can't be found.
    private static func position(_ panel: NSPanel) {
        let size = panel.frame.size
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        var origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 40)
        if let frame = settingsWindowFrame(screenHeight: screen.frame.height) {
            if frame.minX - size.width - 16 > visible.minX {
                origin = NSPoint(x: frame.minX - size.width - 16, y: frame.maxY - size.height - 60)
            } else if frame.minY - size.height - 16 > visible.minY {
                origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY - size.height - 16)
            } else {
                origin = NSPoint(x: frame.maxX - size.width - 24, y: frame.minY + 24)
            }
        }
        panel.setFrameOrigin(origin)
    }

    /// System Settings' frontmost window, in AppKit coordinates. Window bounds and owner names
    /// are readable without the Screen Recording permission.
    private static func settingsWindowFrame(screenHeight: CGFloat) -> NSRect? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard (window[kCGWindowOwnerName as String] as? String) == "System Settings",
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"],
                  width > 300 else { continue }
            return NSRect(x: x, y: screenHeight - y - height, width: width, height: height)
        }
        return nil
    }
}

struct FullDiskAccessCard: View {
    let close: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            AppIconDragSource()
                .frame(width: 62, height: 62)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .help("Drag into the Full Disk Access list")
            VStack(alignment: .leading, spacing: 3) {
                Text("Drag Appears into the list")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.foreground)
                Text("Then turn it on. This card closes once access is on.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Or show it in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                .buttonStyle(.link)
                .font(.system(size: 11.5, weight: .medium))
                .padding(.top, 2)
                .help("Drag it from Finder, or click + in the list and choose it")
            }
            .frame(width: 170, alignment: .leading)
            VStack {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.mutedForeground)
                .help("Close")
                .accessibilityLabel("Close")
                Spacer()
            }
        }
        .padding(14)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
        .fixedSize()
    }
}

/// Appears' icon, draggable as the app itself: an AppKit drag of the bundle's file URL, which
/// is what Finder puts on the pasteboard and what System Settings' privacy lists accept.
/// (SwiftUI's `onDrag` with an item provider isn't accepted there.)
struct AppIconDragSource: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView, NSDraggingSource {
        private var icon: NSImage {
            NSApp?.applicationIconImage ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        }

        override func draw(_ dirtyRect: NSRect) {
            icon.draw(in: bounds.insetBy(dx: 5, dy: 5))
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {}

        override func mouseDragged(with event: NSEvent) {
            let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
            item.setDraggingFrame(bounds.insetBy(dx: 5, dy: 5), contents: icon)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .link, .generic] : []
        }
    }
}
