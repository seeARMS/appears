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
        /// 0 (strict) to 1 (broad). The default maps to a threshold of 0.8.
        public var sensitivity: Double = 5.0 / 7.0
        /// The minimum interval between menu bar signals. There is no hourly budget.
        public var baseGap: TimeInterval = 60

        public init() {}

        /// The decision model's probability a suggestion needs, from the sensitivity slider:
        /// 0.95 at strict, 0.8 by default, 0.74 at broad. At 0.8, H2O measured 2.6% of its
        /// held-out decisions confidently wrong.
        public var threshold: Double { 0.95 - 0.21 * min(max(sensitivity, 0), 1) }
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

    /// Whether a probability is high enough to signal.
    public func isConfident(_ confidence: Double) -> Bool {
        confidence >= settings.threshold
    }

    /// Whether a lookup's results could signal on their own, before anything is suppressed: the
    /// decision model judged them and is sure enough that one of them is what's needed. When two
    /// items both fit, their probabilities split, but the chance that one of them fits doesn't.
    public func isConfident(_ suggestion: Suggestion) -> Bool {
        suggestion.decided && isConfident(suggestion.features.answered ?? 0)
    }

    /// The results an ambient lookup may signal with, most probable first, or none. Only the
    /// results that may still signal here count toward the threshold: an answer already shown
    /// or dismissed in this document or conversation doesn't lend its probability to the rest.
    public func signalable(_ candidates: [Suggestion], maySuggest: (Suggestion) -> Bool) -> [Suggestion] {
        let eligible = candidates.filter { $0.decided && maySuggest($0) }
        guard isConfident(eligible.reduce(0) { $0 + $1.confidence }) else { return [] }
        return eligible.sorted { $0.confidence > $1.confidence }
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
