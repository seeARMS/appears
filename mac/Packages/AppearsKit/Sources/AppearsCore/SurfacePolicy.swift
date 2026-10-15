import Foundation

/// How Appears suggests on its own.
public enum AmbientMode: String, Sendable, Codable, CaseIterable {
    /// Only when asked.
    case off
    /// Looks on its own and logs what it would have shown, but shows nothing.
    case shadow
    /// Changes the menu bar glyph when it has something worth seeing.
    case on
}

/// Decides when an ambient suggestion is allowed to change the menu bar glyph. Most of the
/// time the answer is no: silence is the default, and every ignored or dismissed suggestion
/// makes the next one wait longer.
public struct SurfacePolicy: Sendable {
    public struct Settings: Sendable, Codable, Equatable {
        /// Seconds in one context before Appears looks.
        public var dwell: TimeInterval = 15
        /// 0 (rarely) to 1 (more often). Maps to the confidence a suggestion needs.
        public var sensitivity: Double = 0.5
        public var perHour = 4
        /// The wait after a suggestion, before backoff.
        public var baseGap: TimeInterval = 5 * 60

        public init() {}

        /// The confidence a suggestion needs, from the sensitivity slider.
        public var threshold: Double { 0.85 - 0.35 * min(max(sensitivity, 0), 1) }
    }

    public var settings: Settings
    private(set) var surfacedAt: [Date] = []
    private(set) var shownFingerprints: [String: Date] = [:]
    /// Doubles with each ignored or dismissed suggestion, resets when one is used.
    private(set) var backoff: Double = 1
    private(set) var lastSurface: Date?

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    public enum Decision: Equatable, Sendable {
        case show
        case wait(String)
    }

    /// Whether to look at all: the context has settled long enough and the budget allows.
    public func mayLook(dwell: TimeInterval, fingerprint: String, now: Date = Date()) -> Decision {
        if dwell < settings.dwell { return .wait("dwell") }
        if shownFingerprints[fingerprint] != nil { return .wait("already shown here") }
        if let lastSurface, now.timeIntervalSince(lastSurface) < settings.baseGap * backoff { return .wait("backoff") }
        if surfacedAt.filter({ now.timeIntervalSince($0) < 3_600 }).count >= settings.perHour { return .wait("hourly budget") }
        return .show
    }

    /// Whether a result is good enough to show.
    public func isConfident(_ confidence: Double) -> Bool {
        confidence >= settings.threshold
    }

    public mutating func didSurface(fingerprint: String, at now: Date = Date()) {
        surfacedAt = surfacedAt.filter { now.timeIntervalSince($0) < 3_600 } + [now]
        shownFingerprints[fingerprint] = now
        if shownFingerprints.count > 500 {
            shownFingerprints = shownFingerprints.filter { now.timeIntervalSince($0.value) < 86_400 }
        }
        lastSurface = now
    }

    /// Feed back what happened, so the next suggestion waits more or less.
    public mutating func record(_ outcome: Outcome) {
        if outcome.isUseful {
            backoff = 1
        } else {
            backoff = min(backoff * 2, 32)
        }
    }
}
