import Foundation

/// Debouncing lives in the app; this limits repeat model work after the text settles.
/// Fingerprints are held in memory, and looking never consumes the suggestion budget.
public struct AmbientLookupSchedule: Sendable {
    public var minimumInterval: TimeInterval = 10
    private var completedFingerprint: String?
    private var lastLookedAt: Date?

    public init() {}

    /// Nil means this exact context has already been searched. Edits can search again
    /// after the original topic dwell and the minimum interval have both elapsed.
    public func delay(fingerprint: String, dwell: TimeInterval, requiredDwell: TimeInterval, now: Date = Date()) -> TimeInterval? {
        guard fingerprint != completedFingerprint else { return nil }
        let remainingInterval = lastLookedAt.map { minimumInterval - now.timeIntervalSince($0) } ?? 0
        return max(0, requiredDwell - dwell, remainingInterval)
    }

    public mutating func didStart(at date: Date = Date()) {
        lastLookedAt = date
    }

    public mutating func didFinish(fingerprint: String) {
        completedFingerprint = fingerprint
    }
}
