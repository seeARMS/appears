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

/// Controls signals, independently of lookups. An unnoticed dot or a dismissal never
/// slows other suggestions; an item can signal only once in each document/conversation.
public struct SurfacePolicy: Sendable {
    public struct Settings: Sendable, Codable, Equatable {
        /// Seconds in one context before Appears looks.
        public var dwell: TimeInterval = 1
        /// 0 (strict) to 1 (broad). The default maps to a confidence threshold of 0.6.
        public var sensitivity: Double = 5.0 / 7.0
        /// The minimum interval between menu bar signals. There is no hourly budget.
        public var baseGap: TimeInterval = 60

        public init() {}

        /// The confidence a suggestion needs, from the sensitivity slider.
        public var threshold: Double { 0.85 - 0.35 * min(max(sensitivity, 0), 1) }
    }

    public var settings: Settings
    private var shownItems: [String: Set<Int64>] = [:]
    private var dismissedItems: [String: Set<Int64>] = [:]
    private(set) var lastSurface: Date?

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// Search can run during this gap; only announcing its result must wait.
    public func signalDelay(now: Date = Date()) -> TimeInterval {
        guard let lastSurface else { return 0 }
        return max(0, settings.baseGap - now.timeIntervalSince(lastSurface))
    }

    public func maySuggest(itemID: Int64, topic: String) -> Bool {
        !(shownItems[topic]?.contains(itemID) ?? false) && !isDismissed(itemID: itemID, topic: topic)
    }

    /// Manual asks may repeat an item, but respect a deliberate dismissal in this topic.
    public func isDismissed(itemID: Int64, topic: String) -> Bool {
        dismissedItems[topic]?.contains(itemID) ?? false
    }

    /// Whether a result is good enough to show.
    public func isConfident(_ confidence: Double) -> Bool {
        confidence >= settings.threshold
    }

    public mutating func didSurface(itemIDs: [Int64], topic: String, at now: Date = Date()) {
        shownItems[topic, default: []].formUnion(itemIDs)
        lastSurface = now
    }

    /// Feedback suppresses this item locally, without changing the global signal gap.
    public mutating func record(_ outcome: Outcome, itemID: Int64, topic: String) {
        if outcome == .dismissed || outcome == .blocked {
            dismissedItems[topic, default: []].insert(itemID)
        }
    }
}
