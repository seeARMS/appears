import AppKit
import AppearsContext
import KeyboardShortcuts
import SwiftUI

@main
struct AppearsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // A menu bar app: windows are opened by the delegate.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var status: StatusController?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // First thing: give up the network for the life of this process. See NoNetwork.swift.
        if let error = NoNetwork.apply() {
            NSLog("Appears: couldn't apply the no-network profile: \(error)")
        } else {
            NSLog("Appears: no-network profile applied; test connection %@", NoNetwork.probe() ? "ALLOWED (unexpected)" : "blocked")
        }
        model.noteNetworkBlocked()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let status = StatusController(model: model)
        status.openSettings = { [weak self] in self?.showSettings() }
        self.status = status
        KeyboardShortcuts.onKeyUp(for: .pull) { [weak self] in
            MainActor.assumeIsolated { self?.status?.togglePull() }
        }
        model.start()
        if AppModel.scriptedAsk == nil, !model.settings.onboarded || !ContextReader.isTrusted {
            showOnboarding()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening the app again from Finder or Spotlight shows Settings.
        showSettings()
        return false
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            window.title = "Appears"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false
            )
            window.titlebarAppearsTransparent = true
            window.title = ""
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: OnboardingView(model: model) { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
            })
            window.center()
            onboardingWindow = window
        }
        NSApp.activate()
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }
}
