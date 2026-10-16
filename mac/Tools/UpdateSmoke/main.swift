import AppKit
import Sparkle
import SwiftUI

/// A fixture app, without permissions, an engine, a model or network requests.
/// Exercises the real update preferences/delegates and renders the native dialog.
final class UpdateStateCoder: NSCoder {
    override var allowsKeyedCoding: Bool { true }
    override func decodeInteger(forKey key: String) -> Int { 0 }
    override func decodeBool(forKey key: String) -> Bool { true }
}

@main struct UpdateSmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        defaults.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
        defer { defaults.removePersistentDomain(forName: Bundle.main.bundleIdentifier!) }
        let updater = Updater()
        precondition(updater.checksAutomatically, "Update checks default to on")
        updater.checksAutomatically = false
        precondition(!Updater().checksAutomatically, "Opt-out survives relaunch")
        updater.checksAutomatically = true
        precondition(Updater().checksAutomatically, "Opt-in survives relaunch")
        precondition(Bundle.main.object(forInfoDictionaryKey: "SUScheduledCheckInterval") as? Int == 86_400)
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        func item(url: String = "https://appea.rs/downloads/v0.8.0/Appears.dmg", format: String = "markdown", externalNotes: Bool = false) -> SUAppcastItem {
            var properties: [String: Any] = [
                "title": "Version 0.8.0", "sparkle:version": "80", "sparkle:shortVersionString": "0.8.0",
                "description": ["format": format, "content": "## Changelog\n\n- Faster indexing.\n- Better recall for your old files."],
                "enclosure": ["url": url, "length": "1234", "type": "application/octet-stream"]
            ]
            if externalNotes { properties["sparkle:releaseNotesLink"] = ["content": "https://example.com/notes"] }
            return SUAppcastItem(dictionary: properties)!
        }
        let update = item()
        try updater.updater(controller.updater, shouldProceedWithUpdate: update, updateCheck: .updates)
        for rejected in [item(url: "https://other.example/Appears.dmg"), item(format: "html"), item(externalNotes: true)] {
            do {
                try updater.updater(controller.updater, shouldProceedWithUpdate: rejected, updateCheck: .updates)
                preconditionFailure("Unsafe release should be rejected")
            } catch { }
        }
        let state = SPUUserUpdateState(coder: UpdateStateCoder())!
        precondition(!updater.standardUserDriverShouldHandleShowingScheduledUpdate(update, andInImmediateFocus: true))
        updater.standardUserDriverWillHandleShowingUpdate(false, forUpdate: update, state: state)
        precondition(updater.availableVersion == "0.8.0")

        let output = URL(filePath: ProcessInfo.processInfo.environment["UPDATE_SMOKE_OUTPUT"]!)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            updater.standardUserDriverWillHandleShowingUpdate(false, forUpdate: update, state: state)
            let settings = NSHostingView(rootView: Form { UpdatesSection(updater: updater) }.formStyle(.grouped).frame(width: 560, height: 600))
            settings.frame = NSRect(x: 0, y: 0, width: 560, height: 600)
            capture(settings, to: output.appending(path: "settings-\(name).png"))
            let driver = SPUStandardUserDriver(hostBundle: .main, delegate: updater)
            driver.showUpdateFound(with: update, state: state) { _ in }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            if let content = NSApp.windows.first(where: { $0.isVisible })?.contentView {
                capture(content, to: output.appending(path: "changelog-\(name).png"))
            } else { preconditionFailure("Changelog dialog must be visible after an explicit check") }
            driver.dismissUpdateInstallation()
        }
        updater.standardUserDriverWillFinishUpdateSession()
        precondition(updater.availableVersion == nil)
        print("PASS: daily interval, default-on preference, opt-out persistence, quiet discovery, release validation, native changelog UI")
    }

    @MainActor static func capture(_ view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        let image = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: image)
        let opaque = NSImage(size: view.bounds.size)
        opaque.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        view.bounds.fill()
        NSImage(cgImage: image.cgImage!, size: view.bounds.size).draw(in: view.bounds)
        opaque.unlockFocus()
        let output = NSBitmapImageRep(data: opaque.tiffRepresentation!)!
        try! output.representation(using: .png, properties: [:])!.write(to: url)
    }
}
