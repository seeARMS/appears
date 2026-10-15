import AppKit
import AppearsCore
import CoreGraphics
import ScreenCaptureKit

/// The OCR fallback: when the Accessibility API returns almost nothing (Google Docs and
/// other apps that draw their own text), capture just the frontmost window, read its
/// words with Vision on this Mac, and drop the image. Only on pull, and only with the
/// Screen Recording permission.
public enum ScreenText {
    public static var isAllowed: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    public static func requestAccess() -> Bool { CGRequestScreenCaptureAccess() }

    public static func frontmostWindowText() async -> String? {
        guard isAllowed, let app = await MainActor.run(body: { NSWorkspace.shared.frontmostApplication }) else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let windows = content.windows.filter {
                $0.owningApplication?.processID == app.processIdentifier && $0.windowLayer == 0 && $0.frame.width > 100
            }
            guard let window = windows.first else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            let scale = 2.0
            configuration.width = Int(window.frame.width * scale)
            configuration.height = Int(window.frame.height * scale)
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let text = await Extractor.recognizeText(in: image)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
}
