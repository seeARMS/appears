import AppearsCore
import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// "What do I already have about this?"
    static let pull = Self("pull", default: .init(.space, modifiers: [.command, .shift]))
    /// Search your index by meaning, with a typed query.
    static let search = Self("search", initial: .init(.space, modifiers: [.control, .shift]))
}

enum MatchAlertStyle: String, CaseIterable {
    case motion, dot, toast

    var title: String {
        switch self {
        case .motion: "Motion (default)"
        case .dot: "Dot with no motion"
        case .toast: "Toast with match details"
        }
    }

    var caption: String {
        switch self {
        case .motion: "The menu bar ring rotates while a match waits. Reduce Motion keeps it still."
        case .dot: "A still dot marks a waiting match in the menu bar."
        case .toast: "A brief, silent banner shows the match and its evidence. Click it to see related results."
        }
    }
}

/// Preferences, in UserDefaults. Only settings live here; nothing about what was on screen.
@MainActor @Observable
final class AppSettings {
    private let defaults: UserDefaults

    var ambientMode: AmbientMode {
        didSet { defaults.set(ambientMode.rawValue, forKey: "ambientMode") }
    }
    var matchAlertStyle: MatchAlertStyle {
        didSet { defaults.set(matchAlertStyle.rawValue, forKey: "matchAlertStyle") }
    }
    var sensitivity: Double {
        didSet { defaults.set(sensitivity, forKey: "sensitivity") }
    }
    var dwell: Double {
        didSet { defaults.set(dwell, forKey: "dwell") }
    }
    /// Apps Appears never reads, beyond the built-in list.
    var excludedApps: [String] {
        didSet { defaults.set(excludedApps, forKey: "excludedApps") }
    }
    var sources: SourceSettings {
        didSet { defaults.set(try? JSONEncoder().encode(sources), forKey: "sources") }
    }
    /// Safari can't say whether a window is private, so ambient mode skips Safari unless this is on.
    var ambientInSafari: Bool {
        didSet { defaults.set(ambientInSafari, forKey: "ambientInSafari") }
    }
    /// Read the window with OCR on pull when Accessibility returns almost nothing.
    var ocrOnPull: Bool {
        didSet { defaults.set(ocrOnPull, forKey: "ocrOnPull") }
    }
    var onboarded: Bool {
        didSet { defaults.set(onboarded, forKey: "onboarded") }
    }
    /// Pause until this time.
    var pausedUntil: Date? {
        didSet { defaults.set(pausedUntil, forKey: "pausedUntil") }
    }
    /// Look ahead to meetings: shortly before one, look for what you already have about it.
    /// Needs Calendar access too.
    var calendarContext: Bool {
        didSet { defaults.set(calendarContext, forKey: "calendarContext") }
    }
    /// How long before a meeting to look, in seconds.
    var calendarLead: Double {
        didSet { defaults.set(calendarLead, forKey: "calendarLead") }
    }
    /// Let the answer model (H2O-Lightning-4B, on this Mac) judge which result answers.
    var answerModel: Bool {
        didSet { defaults.set(answerModel, forKey: "answerModel") }
    }
    /// Development builds can keep context snippets in the journal for labelling (14 days).
    var keepDebugContext: Bool {
        didSet { defaults.set(keepDebugContext, forKey: "keepDebugContext") }
    }

    /// Per-install salt for context fingerprints, so they can't be matched across Macs or reversed.
    let salt: String

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ambientMode = AmbientMode(rawValue: defaults.string(forKey: "ambientMode") ?? "") ?? .on
        matchAlertStyle = MatchAlertStyle(rawValue: defaults.string(forKey: "matchAlertStyle") ?? "") ?? .motion
        sensitivity = defaults.object(forKey: "sensitivity") as? Double ?? SurfacePolicy.Settings().sensitivity
        dwell = defaults.object(forKey: "dwell") as? Double ?? SurfacePolicy.Settings().dwell
        excludedApps = defaults.stringArray(forKey: "excludedApps") ?? []
        sources = (defaults.data(forKey: "sources")).flatMap { try? JSONDecoder().decode(SourceSettings.self, from: $0) } ?? SourceSettings()
        ambientInSafari = defaults.bool(forKey: "ambientInSafari")
        ocrOnPull = defaults.object(forKey: "ocrOnPull") as? Bool ?? true
        onboarded = defaults.bool(forKey: "onboarded")
        pausedUntil = defaults.object(forKey: "pausedUntil") as? Date
        calendarContext = defaults.object(forKey: "calendarContext") as? Bool ?? true
        calendarLead = defaults.object(forKey: "calendarLead") as? Double ?? 600
        keepDebugContext = defaults.bool(forKey: "keepDebugContext")
        answerModel = defaults.object(forKey: "answerModel") as? Bool ?? true
        if let salt = defaults.string(forKey: "salt") {
            self.salt = salt
        } else {
            salt = UUID().uuidString
            defaults.set(salt, forKey: "salt")
        }
    }

    var isPaused: Bool { (pausedUntil ?? .distantPast) > Date() }

    var policySettings: SurfacePolicy.Settings {
        var settings = SurfacePolicy.Settings()
        settings.sensitivity = sensitivity
        settings.dwell = dwell
        return settings
    }
}
