import AppKit
import AppearsCore
import EventKit
import os

/// Watches your calendar for the next meeting worth a look and says when it's due: each event
/// once, a lead time before it starts. Nothing polls. A change to the calendar, waking from
/// sleep, a new day or a clock change reschedules, and one timer waits for the next event.
///
/// Events are read in memory and dropped. Nothing about them is logged or stored.
@MainActor
final class CalendarWatcher {
    enum Access {
        case granted, notAsked, denied
    }

    /// Reading events needs full access; write-only access isn't enough.
    static var access: Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    /// Shows macOS's prompt the first time. After that the choice lives in System Settings, so
    /// this opens it there.
    static func requestAccess() async {
        if access == .notAsked {
            _ = try? await EKEventStore().requestFullAccessToEvents()
        } else if access == .denied {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
        }
    }

    /// How long before a meeting to look.
    var lead: TimeInterval = 600 {
        didSet { if lead != oldValue { reschedule() } }
    }
    var onDue: ((CalendarEvent) -> Void)?
    private(set) var isRunning = false

    private var store: EKEventStore?
    private var injected: CalendarEvent?
    private var timer: Task<Void, Never>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Occurrences already looked at. Kept across stop and start, so turning the setting off and
    /// on doesn't look at the same meeting twice.
    private var looked: Set<String> = []
    private let log = Logger(subsystem: "rs.appea.appears", category: "calendar")

    /// Starts watching: the made-up `-event` if there is one, otherwise your calendar, if
    /// `readCalendar` and access is granted.
    func start(injected: CalendarEvent?, readCalendar: Bool) {
        stop()
        self.injected = injected
        if injected == nil {
            guard readCalendar, Self.access == .granted else { return }
            store = EKEventStore()
        }
        isRunning = true
        let center = NotificationCenter.default
        var watched: [(NotificationCenter, Notification.Name, AnyObject?)] = [
            (center, .NSCalendarDayChanged, nil),
            (center, .NSSystemClockDidChange, nil),
            (center, .NSSystemTimeZoneDidChange, nil),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification, nil),
        ]
        if let store { watched.append((center, .EKEventStoreChanged, store)) }
        observers = watched.map { center, name, object in
            (center, center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reschedule() }
            })
        }
        reschedule()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        store = nil
        injected = nil
        isRunning = false
    }

    /// One timer, for the next event's look.
    private func reschedule() {
        timer?.cancel()
        guard isRunning else { return }
        let now = Date()
        let events = upcoming(now)
        // Occurrences that are over drop out of the window, and can't come back.
        looked.formIntersection(events.map(\.id))
        guard let next = CalendarSchedule.next(events, lead: lead, now: now, looked: looked) else {
            log.info("No meeting worth a look in the next day and a half")
            return
        }
        let delay = next.timeIntervalSince(now)
        log.info("Next look ahead to a meeting in \(Int(delay), privacy: .public) s")
        timer = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            self?.fire()
        }
    }

    private func fire() {
        let now = Date()
        for event in CalendarSchedule.due(upcoming(now), lead: lead, now: now, looked: looked) {
            looked.insert(event.id)
            onDue?(event)
        }
        reschedule()
    }

    /// Events from now to a day and a half ahead: enough for the next look, and a new day
    /// reschedules before the window runs out.
    private func upcoming(_ now: Date) -> [CalendarEvent] {
        if let injected { return [injected] }
        guard let store else { return [] }
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(36 * 3_600), calendars: nil)
        return store.events(matching: predicate).compactMap(Self.event)
    }

    static func event(_ event: EKEvent) -> CalendarEvent? {
        guard let start = event.startDate, let end = event.endDate else { return nil }
        let participants = event.attendees ?? []
        let me = participants.first(where: \.isCurrentUser)
        var people = participants.filter { !$0.isCurrentUser && $0.participantType != .room && $0.participantType != .resource }
        if let organizer = event.organizer, !organizer.isCurrentUser, !people.contains(where: { $0.url == organizer.url }) {
            people.append(organizer)
        }
        return CalendarEvent(
            id: (event.eventIdentifier ?? event.calendarItemIdentifier) + "|\(start.timeIntervalSince1970)",
            title: event.title ?? "", start: start, end: end, isAllDay: event.isAllDay,
            declined: event.status == .canceled || me?.participantStatus == .declined,
            attendees: people.map { CalendarEvent.Attendee(name: $0.name, email: email($0.url)) },
            location: event.location ?? "", notes: event.notes ?? ""
        )
    }

    /// "mailto:dana@example.com" → "dana@example.com". Participants without an address have
    /// other kinds of URL.
    static func email(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        let address = String(url.absoluteString.dropFirst("mailto:".count))
        return (address.removingPercentEncoding ?? address).nilIfBlank
    }

    // MARK: - A made-up meeting, for trying it out

    /// `-event "<title>"`: a made-up meeting in place of your calendar, which is then never
    /// read. It starts a little after the lead time from launch, so the whole path runs: the
    /// timer, the look and the menu bar ring. Options: `-event-with "Name <email>; …"`,
    /// `-event-notes "…"`, `-event-location "…"`, `-event-in <seconds until it starts>`.
    /// For example, with `-demo`: `-event "Kitchen walkthrough with Dana Ruiz" -event-with
    /// "Dana Ruiz <dana@ruizdaughters.example>"`.
    static func injectedEvent(lead: TimeInterval, now: Date = Date()) -> CalendarEvent? {
        let args = CommandLine.arguments
        func value(_ name: String) -> String? {
            guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        guard let title = value("-event") else { return nil }
        let start = now.addingTimeInterval(value("-event-in").flatMap(Double.init) ?? lead + 30)
        return CalendarEvent(
            id: "injected|\(start.timeIntervalSince1970)", title: title, start: start, end: start.addingTimeInterval(30 * 60),
            attendees: (value("-event-with") ?? "").split(separator: ";").map { CalendarEvent.Attendee(recipient: String($0)) },
            location: value("-event-location") ?? "", notes: value("-event-notes") ?? ""
        )
    }

    static var isInjecting: Bool { CommandLine.arguments.contains("-event") }
}

private extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespaces).isEmpty ? nil : self }
}
