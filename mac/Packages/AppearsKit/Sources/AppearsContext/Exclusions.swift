import Foundation

/// Apps Appears never reads. Password managers and keychains by default; you can add more
/// ("Not in this app" in the panel, or Settings).
public enum Exclusions {
    public static let defaultBundleIDs: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.dashlane.dashlanephonefinal", "com.lastpass.LastPass",
        "org.keepassxc.keepassxc", "com.apple.keychainaccess", "com.apple.Passwords",
        "com.apple.systempreferences", "com.apple.SecurityAgent", "com.apple.loginwindow",
        "com.apple.ScreenSharing", "rs.appea.appears",
    ]

    /// Why a capture must be thrown away, or nil if it can be used.
    public static func reason(
        for captured: CapturedContext, excludedApps: Set<String>, allowUnknownPrivacy: Bool
    ) -> String? {
        let bundleID = captured.snapshot.bundleID
        if defaultBundleIDs.contains(bundleID) { return "excluded by default" }
        if excludedApps.contains(bundleID) { return "you excluded this app" }
        if captured.isSecure { return "password field" }
        if captured.isPrivate { return "private window" }
        if captured.privacyUnknown, !allowUnknownPrivacy { return "can't tell if this window is private" }
        return nil
    }
}
