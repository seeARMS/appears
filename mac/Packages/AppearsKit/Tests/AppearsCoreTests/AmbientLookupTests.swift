import Foundation
import Testing
@testable import AppearsCore

@Suite struct AmbientLookupTests {
    @Test func readingLooksFiveSecondsAfterEnteringAContext() {
        var schedule = AmbientLookupSchedule()
        let now = Date()
        schedule.didChange(at: now)
        #expect(schedule.settleDelay(now: now.addingTimeInterval(1)) == 1)
        #expect(schedule.delay(fingerprint: "a", topic: "chat-a", requiredDwell: 5, now: now.addingTimeInterval(2)) == 3)
        #expect(schedule.dwell(now: now.addingTimeInterval(5)) == 5)
    }

    @Test func typingInANewConversationBypassesReadingDwell() {
        var schedule = AmbientLookupSchedule()
        let now = Date()
        schedule.didChange(at: now)
        schedule.didChange(textEdited: true, at: now.addingTimeInterval(0.5))
        // Selection notifications following typing must not erase the edit signal.
        schedule.didChange(at: now.addingTimeInterval(0.5))
        #expect(schedule.settleDelay(now: now.addingTimeInterval(1)) == 1.5)
        #expect(schedule.delay(fingerprint: "rent?", topic: "new-chat", requiredDwell: 5, now: now.addingTimeInterval(2.5)) == 0)
        #expect(schedule.dwell(now: now.addingTimeInterval(2.5)) < 5)
    }

    @Test func eachEditRestartsDebounceWithoutAnotherLookupThrottle() {
        var schedule = AmbientLookupSchedule()
        let now = Date()
        schedule.didChange(textEdited: true, at: now)
        schedule.didChange(textEdited: true, at: now.addingTimeInterval(1))
        #expect(schedule.settleDelay(now: now.addingTimeInterval(2)) == 1)
        #expect(schedule.delay(fingerprint: "first draft", topic: "chat", requiredDwell: 5, now: now.addingTimeInterval(3)) == 0)
        schedule.didFinish(fingerprint: "first draft")
        schedule.didChange(textEdited: true, at: now.addingTimeInterval(3.5))
        #expect(schedule.delay(fingerprint: "next draft", topic: "chat", requiredDwell: 5, now: now.addingTimeInterval(5.5)) == 0)
    }

    @Test func unchangedTextIsNotSearchedAgainAndCancelledWorkCanRetry() {
        var schedule = AmbientLookupSchedule()
        let now = Date()
        schedule.didChange(textEdited: true, at: now)
        #expect(schedule.delay(fingerprint: "draft", topic: "chat", requiredDwell: 5, now: now.addingTimeInterval(2)) == 0)
        // No didFinish: the lookup was cancelled.
        schedule.didChange(at: now.addingTimeInterval(3))
        #expect(schedule.delay(fingerprint: "draft", topic: "chat", requiredDwell: 5, now: now.addingTimeInterval(5)) == 0)
        schedule.didFinish(fingerprint: "draft")
        schedule.didChange(at: now.addingTimeInterval(6))
        #expect(schedule.delay(fingerprint: "draft", topic: "chat", requiredDwell: 5, now: now.addingTimeInterval(8)) == nil)
        schedule.invalidate()
        #expect(schedule.delay(fingerprint: "draft", topic: "chat", requiredDwell: 5, now: now.addingTimeInterval(9)) == 0)
    }

    @Test func switchingConversationsStillRequiresReadingDwell() {
        var schedule = AmbientLookupSchedule()
        let now = Date()
        schedule.didChange(textEdited: true, at: now)
        _ = schedule.delay(fingerprint: "old", topic: "old-chat", requiredDwell: 5, now: now.addingTimeInterval(2))
        schedule.didFinish(fingerprint: "old")
        schedule.didChange(at: now.addingTimeInterval(3))
        #expect(schedule.delay(fingerprint: "new", topic: "new-chat", requiredDwell: 5, now: now.addingTimeInterval(5)) == 3)
    }

    @Test func shortComposedQuestionIsEnoughButEmptyWindowsAreNot() {
        #expect(ContextSnapshot(focusedText: "did you pay rent yet?").hasAmbientText)
        #expect(!ContextSnapshot(windowTitle: "Jordan", focusedText: "hi").hasAmbientText)
    }

    @Test func typingInThePreviousWindowDoesNotBypassDwellInANewOne() {
        var schedule = AmbientLookupSchedule()
        let now = Date()
        schedule.didChange(textEdited: true, at: now)
        schedule.didChange(navigation: true, at: now.addingTimeInterval(1))
        #expect(schedule.delay(fingerprint: "reading", topic: "other-window", requiredDwell: 5, now: now.addingTimeInterval(3)) == 3)
    }

    @Test func editsChangeTheDraftButNotItsDeduplicationTopic() {
        var context = ContextSnapshot(bundleID: "com.apple.mail", windowTitle: "Move-out", documentPath: "/demo/move-out.txt",
                                      focusedText: String(repeating: "Earlier discussion. ", count: 50))
        let fingerprint = context.fingerprint(salt: "test")
        let topic = context.topicFingerprint(salt: "test")
        context.focusedText += "Did you pay the final Harbor Oaks apartment rent bill?"
        context.windowTitle += " — Edited"
        #expect(context.fingerprint(salt: "test") != fingerprint)
        #expect(context.topicFingerprint(salt: "test") == topic)
        context.documentPath = "/demo/other.txt"
        #expect(context.topicFingerprint(salt: "test") != topic)
    }
}
