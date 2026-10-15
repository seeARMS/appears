import AppKit
import Foundation

/// The current tab's URL, and whether the window is private, for browsers that say.
/// Safari and Chrome answer through Apple Events (the Automation permission); Firefox only
/// exposes the URL through Accessibility, which `TreeWalk` reads.
public enum Browsers {
    public enum Kind: Sendable {
        case safari, chromium, firefox
    }

    public struct Reading: Sendable {
        public var url: String?
        public var isPrivate = false
        public var privacyUnknown = false
    }

    static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.brave.Browser",
        "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "org.chromium.Chromium",
    ]

    public static func kind(_ bundleID: String) -> Kind? {
        if bundleID == "com.apple.Safari" || bundleID == "com.apple.SafariTechnologyPreview" { return .safari }
        if chromium.contains(bundleID) { return .chromium }
        if bundleID == "org.mozilla.firefox" { return .firefox }
        return nil
    }

    @MainActor
    static func read(_ kind: Kind, bundleID: String) -> Reading {
        switch kind {
        case .safari:
            // Safari has no API that says whether a window is private.
            let url = run("tell application id \"\(bundleID)\" to if (count of windows) > 0 then return URL of current tab of front window")
            return Reading(url: url, isPrivate: false, privacyUnknown: true)
        case .chromium:
            let result = run("""
                tell application id "\(bundleID)"
                    if (count of windows) = 0 then return ""
                    set w to front window
                    return (mode of w) & linefeed & (URL of active tab of w)
                end tell
                """)
            let lines = (result ?? "").split(separator: "\n", maxSplits: 1).map(String.init)
            return Reading(url: lines.count > 1 ? lines[1] : nil, isPrivate: lines.first == "incognito")
        case .firefox:
            // The URL comes from Accessibility; private windows are spotted by their title.
            return Reading()
        }
    }

    @MainActor
    private static func run(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil, let string = result.stringValue, !string.isEmpty else { return nil }
        return string
    }
}
