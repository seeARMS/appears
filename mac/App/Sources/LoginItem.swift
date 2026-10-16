import AppKit
import ServiceManagement

/// The system is the source of truth, including approval changes made in Settings.
@MainActor @Observable
final class LoginItem {
    private(set) var status = SMAppService.mainApp.status
    private(set) var error: String?
    private(set) var updating = false

    var enabled: Bool { status == .enabled || status == .requiresApproval }
    func refresh() { status = SMAppService.mainApp.status }

    func setEnabled(_ enabled: Bool) {
        guard !updating else { return }
        updating = true
        error = nil
        Task {
            defer { refresh(); updating = false }
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
            } catch {
                self.error = "Couldn’t change launch at login. \(error.localizedDescription)"
            }
        }
    }

    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

enum LaunchBehavior {
    /// Login items and session restoration must never open a window or request access.
    /// Reopening from Finder/Spotlight is handled separately by the app delegate.
    static func isBackground(event: NSAppleEventDescriptor?, isDefaultLaunch: Bool? = nil) -> Bool {
        if isDefaultLaunch == false { return true }
        guard let event, event.eventID == kAEOpenApplication else { return false }
        let reason = event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        return reason == keyAELaunchedAsLogInItem || reason == keyAELaunchedAsServiceItem
            || event.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem)?.booleanValue == true
            || event.paramDescriptor(forKeyword: keyAERestoreAppState)?.booleanValue == true
    }
}
