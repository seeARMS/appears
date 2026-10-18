import AppKit
import AppearsCore

/// Exercise preference migration and the native alert lifecycle with fictional matches.
@MainActor
func verifyMatchAlerts(suggestions: [Suggestion], status: EngineStatus) async {
    let suite = "appears-alert-fixture-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    precondition(AppSettings(defaults: defaults).matchAlertStyle == .motion)
    precondition(AppSettings(defaults: defaults).dwell == 1, "New installations must default to one second")
    defaults.set(15.0, forKey: "dwell")
    precondition(AppSettings(defaults: defaults).dwell == 15, "An explicit longer wait must survive relaunch")
    defaults.removeObject(forKey: "dwell")
    for style in MatchAlertStyle.allCases {
        AppSettings(defaults: defaults).matchAlertStyle = style
        precondition(AppSettings(defaults: defaults).matchAlertStyle == style, "Alert style must survive relaunch")
    }
    defaults.set("unknown-future-style", forKey: "matchAlertStyle")
    precondition(AppSettings(defaults: defaults).matchAlertStyle == .motion)

    let model = AppModel()
    model.settings = AppSettings(defaults: defaults)
    model.showForSnapshot(nil, status: status)
    let controller = StatusController(model: model)
    defer { controller.close() }
    var sequence = 0
    func entry(_ mode: JournalEntry.Mode = .ambient) -> AppModel.Shown {
        sequence += 1
        return .init(mode: mode, appName: "Mail", windowTitle: "Kitchen quote", fingerprint: "fixture-\(sequence)",
                     suggestions: suggestions, evidenceTerms: ["kitchen", "outlet"], at: Date(timeIntervalSince1970: Double(sequence)))
    }
    func settle() async { try? await Task.sleep(for: .milliseconds(100)) }
    for style in [MatchAlertStyle.motion, .dot] {
        model.settings.matchAlertStyle = style
        model.waitForSnapshot(entry())
        await settle()
        precondition(model.glyph == .found && !controller.isToastVisible)
    }
    model.settings.matchAlertStyle = .toast
    await settle()
    precondition(!controller.isToastVisible, "Changing style must not replay a waiting match")

    let discovery = entry()
    let previousKey = NSApp.keyWindow
    let previousApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
    model.waitForSnapshot(discovery)
    await settle()
    precondition(controller.isToastVisible, "A new confident discovery must show a toast")
    precondition(NSApp.keyWindow === previousKey, "Toasts cannot take keyboard focus")
    precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == previousApp, "Toasts cannot activate Appears")
    model.openWaitingMatch(at: Date.distantPast)
    precondition(model.waiting?.at == discovery.at, "A stale toast cannot open a replacement discovery")
    model.openWaitingMatch(at: discovery.at)
    await settle()
    precondition(model.shown?.at == discovery.at && model.waiting == nil && controller.isVisible && !controller.isToastVisible)
    controller.close()

    model.waitForSnapshot(entry())
    await settle()
    precondition(controller.isToastVisible)
    model.settings.matchAlertStyle = .dot
    await settle()
    precondition(!controller.isToastVisible, "Changing away from toast must remove its content")
    model.settings.matchAlertStyle = .toast
    await settle()
    precondition(!controller.isToastVisible)
    model.waitForSnapshot(entry())
    await settle()
    model.pause(for: 60)
    await settle()
    precondition(!controller.isToastVisible && model.waiting == nil)
    model.settings.pausedUntil = nil
    model.waitForSnapshot(entry())
    await settle()
    precondition(controller.isToastVisible)
    model.setAmbientMode(.off)
    await settle()
    precondition(!controller.isToastVisible)
    model.settings.ambientMode = .shadow
    model.waitForSnapshot(entry(.shadow))
    await settle()
    precondition(!controller.isToastVisible, "Log only mode must never show a toast")
    model.settings.ambientMode = .on
    model.waitForSnapshot(entry(.pull))
    await settle()
    precondition(!controller.isToastVisible, "Explicit pulls must never show a toast")
    model.waitForSnapshot(entry())
    await settle()
    precondition(controller.isToastVisible)
    model.waitForSnapshot(nil)
    await settle()
    precondition(!controller.isToastVisible, "Clearing a stale context must clear the toast")

    let toast = MatchToastController(duration: .milliseconds(100))
    toast.show(discovery, contacts: model.contacts, screen: NSScreen.main, open: {})
    precondition(toast.isVisible)
    try? await Task.sleep(for: .milliseconds(250))
    precondition(!toast.isVisible, "Toasts must expire automatically")

    let hoveredToast = MatchToastController(duration: .seconds(1))
    hoveredToast.show(discovery, contacts: model.contacts, screen: NSScreen.main, open: {})
    try? await Task.sleep(for: .milliseconds(650))
    hoveredToast.setHovering(true)
    try? await Task.sleep(for: .milliseconds(1100))
    precondition(hoveredToast.isVisible, "Hovering must pause expiry")
    hoveredToast.setHovering(false)
    try? await Task.sleep(for: .milliseconds(550))
    precondition(!hoveredToast.isVisible, "Leaving hover must resume the remaining time, not a full duration")
    hoveredToast.show(discovery, contacts: model.contacts, screen: NSScreen.main, open: {})
    try? await Task.sleep(for: .milliseconds(550))
    precondition(hoveredToast.isVisible, "A new toast must receive its full duration")
    hoveredToast.dismiss()

    toast.show(discovery, contacts: model.contacts, screen: NSScreen.main, open: {})
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
    precondition(!toast.isVisible, "Display sleep must clear the toast")
    toast.show(discovery, contacts: model.contacts, screen: NSScreen.main, open: {})
    precondition(!toast.isVisible, "Discoveries during display sleep must remain quiet")
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
    precondition(!toast.isVisible, "Waking must not replay an alert")
    toast.show(discovery, contacts: model.contacts, screen: NSScreen.main, open: {})
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
    precondition(!toast.isVisible, "Leaving the user session must clear the toast")
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    print("Verified alert persistence, motion/dot/toast routing, focus, opening, stale alerts, pause, off/log-only, expiry, hover and sleep")
}
