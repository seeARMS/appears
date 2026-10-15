import Foundation
import Testing

@testable import AppearsCore

/// Upcoming meetings as a context. All made up; phone numbers in 555-01xx.
@Suite struct CalendarTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let dana = CalendarEvent.Attendee(name: "Dana Ruiz", email: "dana@ruizdaughters.example")

    func event(_ title: String = "Kitchen walkthrough with Dana Ruiz", in minutes: Double = 30, attendees: [CalendarEvent.Attendee]? = nil,
               notes: String = "", location: String = "", allDay: Bool = false, declined: Bool = false) -> CalendarEvent {
        let start = now.addingTimeInterval(minutes * 60)
        return CalendarEvent(id: title + "|\(minutes)", title: title, start: start, end: start.addingTimeInterval(1_800), isAllDay: allDay,
                             declined: declined, attendees: attendees ?? [dana], location: location, notes: notes)
    }

    @Test func stripsZoom() {
        let notes = """
            Walk through the cabinet layout. Call Dana at (510) 555-0142 if late.

            Dana Ruiz is inviting you to a scheduled Zoom meeting.
            Join Zoom Meeting
            https://us02web.zoom.us/j/81234567890?pwd=abc

            Meeting ID: 812 3456 7890
            Passcode: 4417
            ---
            One tap mobile
            +16695550100,,81234567890#,,,,*4417# US (San Jose)
            Dial by your location
            • +1 669 555 0100 US (San Jose)
            Find your local number: https://us02web.zoom.us/u/kabc
            Join by SIP
            • 81234567890@zoomcrc.com
            Join by H.323
            • 162.255.37.11 (US West)
            """
        #expect(CalendarEvent.clean(notes) == "Walk through the cabinet layout. Call Dana at (510) 555-0142 if late.")
    }

    @Test func stripsGoogleMeet() {
        let notes = """
            Bring the 1099s.
            -::~:~::~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~::~:~::-
            Join with Google Meet: https://meet.google.com/abc-defg-hij
            Or dial: (US) +1 650-555-0123 PIN: 482913775#
            Please do not edit this section.
            -::~:~::~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~::~:~::-
            Invitation from Google Calendar: https://calendar.google.com/calendar/
            """
        #expect(CalendarEvent.clean(notes) == "Bring the 1099s.")
    }

    @Test func stripsTeams() {
        let notes = """
            Appeal for the crown claim.
            ________________________________________________________________________________
            Microsoft Teams meeting
            Join on your computer, mobile app or room device
            Click here to join the meeting<https://teams.microsoft.com/l/meetup-join/19%3ameeting>
            Meeting ID: 245 550 199 012
            Passcode: 7Hq2Lp
            Download Teams<https://www.microsoft.com/teams> | Join on the web<https://www.microsoft.com/join>
            Or call in (audio only)
            +1 323-555-0142,,245550199#   United States, Los Angeles
            Phone Conference ID: 245 550 199#
            Learn More<https://aka.ms/JoinTeamsMeeting> | Meeting options<https://teams.microsoft.com/meetingOptions/>
            ________________________________________________________________________________
            """
        #expect(CalendarEvent.clean(notes) == "Appeal for the crown claim.")
    }

    @Test func keepsWhatIsntBoilerplate() {
        let notes = """
            Meeting ideas for the offsite: Carmel Valley Ranch.
            Invoice #20231187 is still open.
            Agenda: https://docs.example.com/agenda
            Spin: keep it short.
            """
        #expect(CalendarEvent.clean(notes) == notes)
        #expect(CalendarEvent.clean("Zoom") == "")
        #expect(CalendarEvent.clean("https://northwind.zoom.us/j/9876543210") == "")
        #expect(CalendarEvent.clean("Microsoft Teams Meeting") == "")
        #expect(CalendarEvent.clean("2214 Alcatraz Ave, Oakland CA 94609") == "2214 Alcatraz Ave, Oakland CA 94609")
    }

    @Test func decidesWhichEventsAreWorthALook() {
        #expect(event().isWorthLooking)
        #expect(!event(allDay: true).isWorthLooking)
        #expect(!event(declined: true).isWorthLooking)
        // A solo block: worth it only with something written in it.
        #expect(!event("Focus time", attendees: []).isWorthLooking)
        #expect(!event("Dentist", attendees: []).isWorthLooking)
        #expect(!event("Standup", attendees: [], notes: "Join Zoom Meeting\nhttps://zoom.us/j/123456789").isWorthLooking)
        #expect(event("Biscuit: dental cleaning", attendees: [], notes: "Ask Dr. Patel about the quote.").isWorthLooking)
        #expect(!event("", attendees: [dana]).isWorthLooking)
    }

    @Test func becomesAContext() {
        let meeting = event(attendees: [dana, .init(email: "joan@pinehollow.example")],
                            notes: "Cabinets and outlets.\nJoin Zoom Meeting\nhttps://zoom.us/j/1", location: "2214 Alcatraz Ave")
        let context = meeting.snapshot(at: now)
        #expect(context.bundleID == CalendarEvent.bundleID)
        #expect(context.appName == "Calendar")
        #expect(context.origin == .calendar)
        #expect(context.windowTitle == "Kitchen walkthrough with Dana Ruiz")
        #expect(context.recipients == ["Dana Ruiz <dana@ruizdaughters.example>", "joan@pinehollow.example"])
        #expect(context.visibleText == "2214 Alcatraz Ave\nCabinets and outlets.")
        let query = QueryBuilder.build(context)
        #expect(query.entities.contains("Dana Ruiz"))
        #expect(!query.dense.contains("zoom"))
        // A virtual location says nothing.
        #expect(event(location: "Microsoft Teams Meeting").snapshot().visibleText.isEmpty)
    }

    @Test func readsRecipientsBack() {
        let attendee = CalendarEvent.Attendee(recipient: "Dana Ruiz <dana@ruizdaughters.example>")
        #expect(attendee == dana)
        #expect(CalendarEvent.Attendee(recipient: "dana@ruizdaughters.example").email == "dana@ruizdaughters.example")
        #expect(CalendarEvent.Attendee(recipient: "Dana Ruiz").name == "Dana Ruiz")
        #expect(CalendarEvent.Attendee(name: "dana@x.example", email: "dana@x.example").recipient == "dana@x.example")
    }

    @Test func schedulesOneLookPerEventAtTheLeadTime() {
        let lead: TimeInterval = 600
        let soon = event("Kitchen walkthrough", in: 30)
        let later = event("Offsite planning", in: 90)
        let solo = event("Focus time", in: 15, attendees: [])
        let events = [later, solo, soon]
        // The next look is for the next event worth one, a lead time before it.
        #expect(CalendarSchedule.next(events, lead: lead, now: now, looked: []) == soon.start.addingTimeInterval(-lead))
        #expect(CalendarSchedule.due(events, lead: lead, now: now, looked: []).isEmpty)
        // At the lead time it's due, once.
        let then = soon.start.addingTimeInterval(-lead)
        #expect(CalendarSchedule.due(events, lead: lead, now: then, looked: []) == [soon])
        #expect(CalendarSchedule.due(events, lead: lead, now: then, looked: [soon.id]).isEmpty)
        #expect(CalendarSchedule.next(events, lead: lead, now: then, looked: [soon.id]) == later.start.addingTimeInterval(-lead))
        // Waking up inside the lead time: due now. After the start: never.
        let inside = soon.start.addingTimeInterval(-60)
        #expect(CalendarSchedule.next(events, lead: lead, now: inside, looked: []) == inside)
        #expect(CalendarSchedule.due(events, lead: lead, now: inside, looked: []) == [soon])
        let started = soon.start.addingTimeInterval(1)
        #expect(CalendarSchedule.due([soon], lead: lead, now: started, looked: []).isEmpty)
        #expect(CalendarSchedule.next([soon], lead: lead, now: started, looked: []) == nil)
    }

    @Test func journalCountsMeetingsApart() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "appears-tests-\(UUID().uuidString)")
        let journal = try Journal(url: folder.appending(path: "journal.sqlite"))
        let meeting = try journal.log(JournalEntry(mode: .ambient, bundleID: CalendarEvent.bundleID, fingerprint: "m", dwellSeconds: 0, suggestions: []))
        try journal.log(JournalEntry(mode: .shadow, bundleID: CalendarEvent.bundleID, fingerprint: "n", dwellSeconds: 0, suggestions: []))
        try journal.log(JournalEntry(mode: .ambient, bundleID: "com.apple.mail", fingerprint: "w", dwellSeconds: 15, suggestions: []))
        try journal.record(.opened, entryID: meeting, itemID: 1, position: 0)
        let stats = try journal.stats(days: 1)
        #expect(stats.calendar == 2)
        #expect(stats.calendarPrecision == 1)
        #expect(stats.ambient == 2)
    }
}
