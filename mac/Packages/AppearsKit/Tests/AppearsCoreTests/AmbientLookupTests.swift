import Foundation
import Testing
@testable import AppearsCore

@Suite struct AmbientLookupTests {
    @Test func editsInTheSameConversationCanLookAgain() {
        let now = Date()
        var schedule = AmbientLookupSchedule()
        var context = ContextSnapshot(bundleID: "com.apple.MobileSMS", windowTitle: "Jordan Vale", focusedText: "Want to go for a walk?")
        let first = context.fingerprint(salt: "test")
        #expect(schedule.delay(fingerprint: first, dwell: 2, requiredDwell: 15, now: now) == 13)
        schedule.didStart(at: now)
        schedule.didFinish(fingerprint: first)
        #expect(schedule.delay(fingerprint: first, dwell: 30, requiredDwell: 15, now: now.addingTimeInterval(30)) == nil)

        let topic = context.topic
        context.focusedText = "Did you pay the final Harbor Oaks apartment rent bill?"
        #expect(context.topic == topic)
        let edited = context.fingerprint(salt: "test")
        #expect(schedule.delay(fingerprint: edited, dwell: 18, requiredDwell: 15, now: now.addingTimeInterval(3)) == 7)
        #expect(schedule.delay(fingerprint: edited, dwell: 25, requiredDwell: 15, now: now.addingTimeInterval(10)) == 0)
        schedule.didStart(at: now.addingTimeInterval(10))
        schedule.didFinish(fingerprint: edited)
        #expect(schedule.delay(fingerprint: edited, dwell: 35, requiredDwell: 15, now: now.addingTimeInterval(20)) == nil)
    }

    @Test func editsAtTheEndOfLongDraftsInvalidateAnAnswer() {
        var context = ContextSnapshot(bundleID: "com.apple.mail", windowTitle: "Re: Move-out", focusedText: String(repeating: "Earlier discussion. ", count: 50))
        let before = context.fingerprint(salt: "test")
        context.focusedText += "Did you pay the final Harbor Oaks apartment rent bill?"
        #expect(context.fingerprint(salt: "test") != before)
    }

    @Test func switchingConversationsStillRequiresDwell() {
        var schedule = AmbientLookupSchedule()
        let now = Date()
        schedule.didStart(at: now)
        schedule.didFinish(fingerprint: "old conversation")
        #expect(schedule.delay(fingerprint: "new conversation", dwell: 0, requiredDwell: 15, now: now.addingTimeInterval(1)) == 15)
    }

    @Test func cancelledLookupCanRetryAfterTheMinimumInterval() {
        var schedule = AmbientLookupSchedule()
        let now = Date()
        schedule.didStart(at: now)
        #expect(schedule.delay(fingerprint: "draft", dwell: 30, requiredDwell: 15, now: now.addingTimeInterval(2)) == 8)
        #expect(schedule.delay(fingerprint: "draft", dwell: 38, requiredDwell: 15, now: now.addingTimeInterval(10)) == 0)
    }
}
