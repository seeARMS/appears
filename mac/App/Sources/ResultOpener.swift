import AppKit
import AppearsCore

/// Send message links to Messages explicitly, regardless of the default SMS handler.
@MainActor
enum ResultOpener {
    static func open(_ item: Item) async -> Bool {
        guard let url = item.openURL else { return false }
        guard item.source == .messages else { return NSWorkspace.shared.open(url) }
        if url.isFileURL, NSWorkspace.shared.open(url) { return true }
        guard let messageURL = item.messageURL else { return false }
        let app = URL(filePath: "/System/Applications/Messages.app")
        if messageURL.isFileURL { return NSWorkspace.shared.open(messageURL) }
        do {
            _ = try await NSWorkspace.shared.open([messageURL], withApplicationAt: app, configuration: .init())
            return true
        } catch {
            return NSWorkspace.shared.open(app)
        }
    }
}
