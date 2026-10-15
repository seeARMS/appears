import Foundation

/// An upcoming event, as a context: the minutes before a meeting are a good moment to bring
/// back what you already have about it ("Kitchen walkthrough with Dana Ruiz" → the photo of
/// her quote and the permit). The app reads it from EventKit; it lives in memory only, like
/// any other context, and the journal keeps a salted fingerprint, never its text.
public struct CalendarEvent: Sendable, Equatable {
    public struct Attendee: Sendable, Equatable {
        public var name: String?
        public var email: String?

        public init(name: String? = nil, email: String? = nil) {
            self.name = name
            self.email = email
        }

        /// "Dana Ruiz <dana@ruizdaughters.example>", as a mail window's recipients read.
        public var recipient: String? {
            let name = name?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            let email = email?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            switch (name, email) {
            case let (name?, email?): return name.caseInsensitiveCompare(email) == .orderedSame ? email : "\(name) <\(email)>"
            case let (name?, nil): return name
            case let (nil, email?): return email
            default: return nil
            }
        }

        /// The other way round, for the eval and the `-event` launch argument.
        public init(recipient: String) {
            let text = recipient.trimmingCharacters(in: .whitespaces)
            if let open = text.firstIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
                name = text[..<open].trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "\""))).nilIfEmpty
                email = text[text.index(after: open)..<close].trimmingCharacters(in: .whitespaces).nilIfEmpty
            } else if text.contains("@") {
                email = text
            } else {
                name = text.nilIfEmpty
            }
        }
    }

    /// Stands in for an app's bundle ID in contexts, the journal and Stats, so suggestions made
    /// before a meeting can be told apart from ones made from a window.
    public static let bundleID = "rs.appea.appears.calendar"
    public static let appName = "Calendar"

    /// Identifies this occurrence (a recurring event's occurrences share an event identifier).
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// You declined it, or it was cancelled.
    public var declined: Bool
    /// Everyone else invited: people only, not rooms or resources, and not you.
    public var attendees: [Attendee]
    public var location: String
    public var notes: String

    public init(
        id: String, title: String, start: Date, end: Date, isAllDay: Bool = false, declined: Bool = false,
        attendees: [Attendee] = [], location: String = "", notes: String = ""
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.declined = declined
        self.attendees = attendees
        self.location = location
        self.notes = notes
    }

    /// Whether the event is worth a look at all. All-day events, declined ones, and blocks
    /// with nobody else and nothing written in them ("Focus time", "Dentist") say too little.
    public var isWorthLooking: Bool {
        guard !isAllDay, !declined, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let others = attendees.contains { $0.recipient != nil }
        return others || !Self.clean(notes).isEmpty
    }

    /// The event as a context: the title stands in for the window's title, the attendees for
    /// a mail window's recipients, and the location and notes for the window's text, with
    /// conferencing boilerplate (join links, dial-ins, passcodes) taken out.
    public func snapshot(at now: Date = Date()) -> ContextSnapshot {
        let place = Self.clean(location)
        let text = [place, Self.clean(notes)].filter { !$0.isEmpty }.joined(separator: "\n")
        return ContextSnapshot(
            appName: Self.appName, bundleID: Self.bundleID, windowTitle: title.trimmingCharacters(in: .whitespacesAndNewlines),
            visibleText: text, recipients: attendees.compactMap(\.recipient), origin: .calendar, capturedAt: now
        )
    }

    // MARK: - Conferencing boilerplate

    /// Notes or a location without join links, dial-in numbers, meeting IDs, passcodes and the
    /// rest of what Zoom, Google Meet, Teams and Webex paste into invitations.
    public static func clean(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        var kept: [String] = []
        var fenced = false
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            // Google Calendar fences its Meet block with "-::~:~::~:~…" lines.
            if line.hasPrefix("-::~") {
                fenced.toggle()
                continue
            }
            if fenced { continue }
            line = removingConferencingLinks(line)
            if isBoilerplate(line) { continue }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Hosts whose links are only ever "join the call".
    static let conferencingHosts = [
        "zoom.us", "zoom.com", "zoomgov.com", "meet.google.com", "tel.meet", "teams.microsoft.com", "teams.live.com",
        "aka.ms", "webex.com", "gotomeeting.com", "gotomeet.me", "goto.com", "bluejeans.com", "chime.aws",
        "whereby.com", "meet.jit.si", "facetime.apple.com", "around.co", "dialin.", "zoomcrc.com",
    ]

    /// Phrases that only appear in the part of an invitation that gets you into a call, or in
    /// the footer every invitation carries. Matched as whole words.
    static let boilerplatePhrases = [
        "is inviting you to a scheduled zoom meeting", "join zoom meeting", "zoom meeting", "meeting id", "meeting url",
        "passcode", "password:", "pin:", "one tap mobile", "dial by your location", "find your local number", "join by sip",
        "join by h.323", "join by skype", "skype for business", "microsoft lync", "join with google meet", "google meet",
        "or dial", "more phone numbers", "learn more about meet", "please do not edit this section",
        "microsoft teams meeting", "join on your computer", "click here to join", "download teams", "join on the web",
        "or call in", "phone conference id", "conference id", "find a local number", "reset pin", "meeting options",
        "join the meeting now", "access code", "dial-in", "dial in", "audio only", "join webex meeting", "webex meeting",
        "meeting number", "meeting link", "meeting password", "join by phone", "join by video system", "join from",
        "if you are a host", "host key", "tap to join", "invitation from google calendar", "you are receiving this",
        "forwarding this invitation", "view all guest info", "reply for", "learn more", "need help?",
    ]

    static let boilerplate: NSRegularExpression = {
        let alternatives = boilerplatePhrases.map { phrase in
            NSRegularExpression.escapedPattern(for: phrase) + (phrase.last!.isLetter ? "(?![a-z])" : "")
        }
        return try! NSRegularExpression(pattern: "(?<![a-z])(?:" + alternatives.joined(separator: "|") + ")")
    }()

    /// Any of `conferencingHosts` as a domain ("us02web.zoom.us/j/…", "…@zoomcrc.com").
    static let conferencingHost: NSRegularExpression = {
        let alternatives = conferencingHosts.map { host in
            NSRegularExpression.escapedPattern(for: host) + (host.hasSuffix(".") ? "" : "(?![a-z0-9])")
        }
        return try! NSRegularExpression(pattern: "(?<![a-z0-9-])(?:" + alternatives.joined(separator: "|") + ")")
    }()

    /// A location or a line that names only the kind of call.
    static let virtualPlaces: Set<String> = [
        "zoom", "teams", "microsoft teams", "webex", "google meet", "meet", "facetime", "phone", "phone call", "call",
        "video call", "online", "virtual", "remote", "tbd",
    ]

    static func isBoilerplate(_ line: String) -> Bool {
        let lower = line.lowercased()
        // Separators and bullets on their own, and lines emptied by taking a link out. Blank
        // lines stay: they separate paragraphs.
        if lower.allSatisfy({ !$0.isLetter && !$0.isNumber }) { return !lower.isEmpty }
        if virtualPlaces.contains(lower.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))) { return true }
        if boilerplate.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil { return true }
        if conferencingHost.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil { return true }
        // Dial-in lines: "+1 669 444 9171 US (San Jose)", "+16694449171,,81234567890#,,,,*123456# US",
        // and H.323 addresses, "162.255.37.11 (US West)". A phone number inside a sentence stays.
        let body = lower.drop { "•·-*–— ".contains($0) }
        let digits = body.filter(\.isNumber).count
        if body.hasPrefix("+"), digits >= 7 { return true }
        if digits >= 7, body.contains(",,") || body.range(of: #"\d{4,}#"#, options: .regularExpression) != nil { return true }
        if body.range(of: #"^\d{1,3}(\.\d{1,3}){3}\b"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// Takes "https://us02web.zoom.us/j/8123…" and Teams' "<https://teams.microsoft.com/…>" out
    /// of a line, leaving the rest ("Agenda: <link>" keeps "Agenda:").
    static func removingConferencingLinks(_ line: String) -> String {
        guard line.contains("://") || line.contains("www.") else { return line }
        let pattern = #"<?(?:https?://|www\.)[^\s<>]+>?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return line }
        var result = line
        for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let link = result[range].lowercased()
            let host = conferencingHost.firstMatch(in: link, range: NSRange(link.startIndex..., in: link)) != nil
            if host || link.contains("calendar.google.com") || link.contains("support.google.com") {
                result.replaceSubrange(range, with: "")
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

/// When to look at which event: each one once, a lead time before it starts. One timer for
/// the next one; nothing polls.
public enum CalendarSchedule {
    /// The events to look at now: worth looking at, not looked at yet, starting within the
    /// lead time and not started yet.
    public static func due(_ events: [CalendarEvent], lead: TimeInterval, now: Date, looked: Set<String>) -> [CalendarEvent] {
        events
            .filter { $0.isWorthLooking && !looked.contains($0.id) && $0.start > now && $0.start.addingTimeInterval(-lead) <= now }
            .sorted { $0.start < $1.start }
    }

    /// When the next look is due, or nil when nothing coming up is worth one.
    public static func next(_ events: [CalendarEvent], lead: TimeInterval, now: Date, looked: Set<String>) -> Date? {
        events
            .filter { $0.isWorthLooking && !looked.contains($0.id) && $0.start > now }
            .map { max(now, $0.start.addingTimeInterval(-lead)) }
            .min()
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
