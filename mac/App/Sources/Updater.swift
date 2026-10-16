import AppKit
import Foundation
import SwiftUI

#if canImport(Sparkle)
import Sparkle
#endif

/// Sparkle schedules one check per day, including an overdue check after relaunch.
/// Its patched framework has no network implementation or web views: all downloads
/// run in its sandboxed Downloader.xpc. Release notes are embedded Markdown.
@MainActor @Observable
final class Updater: NSObject {
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    private(set) var availableVersion: String?
    private(set) var lastChecked: Date?
    private(set) var canCheck = false
    private(set) var configurationError: String?

    var checksAutomatically: Bool {
        didSet {
            #if canImport(Sparkle)
            controller.updater.automaticallyChecksForUpdates = checksAutomatically
            #endif
        }
    }

    #if canImport(Sparkle)
    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    #endif

    override init() {
        checksAutomatically = UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true
        super.init()
        #if canImport(Sparkle)
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        #endif
    }

    func start() {
        #if canImport(Sparkle)
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        // Development builds have no update key; they simply never check.
        guard Data(base64Encoded: key)?.count == 32 else { return }
        do {
            try controller.updater.start()
            observations = [
                controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
                    let value = change.newValue ?? false
                    Task { @MainActor [weak self] in self?.canCheck = value }
                },
                controller.updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] _, change in
                    let value = change.newValue ?? nil
                    Task { @MainActor [weak self] in self?.lastChecked = value }
                }
            ]
        } catch {
            configurationError = "Couldn't start update checks. \(error.localizedDescription)"
        }
        #endif
    }

    func checkNow() {
        #if canImport(Sparkle)
        guard canCheck else { return }
        controller.checkForUpdates(nil)
        #endif
    }
}

#if canImport(Sparkle)
extension Updater: SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Leave scheduled discoveries in Settings and the menu. Only an explicit
        // click opens the version/changelog dialog; never steal the user's focus.
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        availableVersion = update.displayVersionString
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        // Remote feeds cannot choose other hosts, web-based notes or installer packages.
        guard let url = updateItem.fileURL,
              url.absoluteString.range(of: #"^https://appea\.rs/downloads/v[0-9]+\.[0-9]+\.[0-9]+/Appears\.dmg$"#, options: .regularExpression) != nil,
              updateItem.installationType == "application",
              updateItem.releaseNotesURL == nil,
              updateItem.itemDescriptionFormat == "markdown" || updateItem.itemDescriptionFormat == "plain-text" else {
            throw NSError(domain: "AppearsUpdates", code: 1, userInfo: [NSLocalizedDescriptionKey: "This update doesn't match Appears' release format."])
        }
    }
}
#endif
