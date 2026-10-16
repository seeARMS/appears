import Foundation

/// chat.db stores dates as time since 2001-01-01 UTC: nanoseconds in current versions of
/// macOS, seconds in rows written before High Sierra.
public enum AppleDate {
    /// Values above this are nanoseconds. A seconds value this large would be the year 33,700.
    static let nanosecondThreshold: Int64 = 1_000_000_000_000

    public static func date(fromChatDB value: Int64) -> Date? {
        guard value > 0 else { return nil }
        let seconds = value > nanosecondThreshold ? Double(value) / 1_000_000_000 : Double(value)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// The nanosecond value current versions of Messages write. Dates beyond what nanoseconds
    /// can hold, like `.distantPast`, clamp to the ends of the range.
    public static func chatDBValue(from date: Date) -> Int64 {
        let nanoseconds = (date.timeIntervalSinceReferenceDate * 1_000_000_000).rounded()
        if nanoseconds <= Double(Int64.min) { return Int64.min }
        if nanoseconds >= Double(Int64.max) { return Int64.max }
        return Int64(nanoseconds)
    }
}
