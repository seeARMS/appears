import Foundation

/// One second reading by default OR a one-second pause after editing. The app cancels its timers
/// immediately on each change. Only fingerprints and timing state are retained here.
public struct AmbientLookupSchedule: Sendable {
    public var debounce: TimeInterval = 1
    private var changeStartedAt: Date?
    private var lastChangeAt: Date?
    private var textEdited = false
    private var topic: String?
    private var topicSince: Date?
    private var completedFingerprint: String?

    public init() {}

    public mutating func didChange(textEdited: Bool = false, navigation: Bool = false, at now: Date = Date()) {
        if navigation {
            changeStartedAt = now
            self.textEdited = false
        }
        if changeStartedAt == nil { changeStartedAt = now }
        lastChangeAt = now
        self.textEdited = self.textEdited || textEdited
    }

    public func settleDelay(now: Date = Date()) -> TimeInterval {
        max(0, debounce - now.timeIntervalSince(lastChangeAt ?? now))
    }

    /// Called after debouncing. A real edit bypasses the reading dwell, including in a
    /// newly entered conversation. There is no additional lookup throttle.
    public mutating func delay(fingerprint: String, topic: String, requiredDwell: TimeInterval, now: Date = Date()) -> TimeInterval? {
        if self.topic != topic {
            self.topic = topic
            topicSince = changeStartedAt ?? now
        }
        let edited = textEdited
        changeStartedAt = nil
        textEdited = false
        guard fingerprint != completedFingerprint else { return nil }
        return edited ? 0 : max(0, requiredDwell - dwell(now: now))
    }

    public func dwell(now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(topicSince ?? now))
    }

    public mutating func didFinish(fingerprint: String) {
        completedFingerprint = fingerprint
    }

    public mutating func invalidate() {
        completedFingerprint = nil
    }
}
