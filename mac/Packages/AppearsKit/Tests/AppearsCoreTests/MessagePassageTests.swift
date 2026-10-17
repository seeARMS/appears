import AppearsMessages
import Foundation
import Testing
@testable import AppearsCore

struct MessagePassageTests {
    private let date = Date(timeIntervalSince1970: 1_780_000_000)
    private func message(_ id: Int64, _ text: String, offset: Double = 0, reply: String? = nil, retracted: Bool = false) -> Message {
        Message(rowID: id, guid: "message-\(id)", chatID: 1, handleID: 1, isFromMe: false,
                date: date.addingTimeInterval(offset), text: text, service: "iMessage", editedAt: nil,
                isRetracted: retracted, kind: .normal, attachments: [], replyToGUID: reply)
    }

    @Test func joinsSpecificReferencesAcrossGapsAndKeepsOriginalDatesAndWords() {
        let subject = message(1, "The revised cabinet delivery is reference 482.")
        let acknowledgement = message(2, "I will handle reference 482.", offset: 5_400)
        let unrelated = message(3, "Would you like noodles for dinner?", offset: 2_700)
        let removed = message(4, "Reference 482 was cancelled.", offset: 5_420, retracted: true)
        let result = MessagePassage.discussion(anchor: acknowledgement, messages: [subject, unrelated, acknowledgement, removed], handles: [:])
        #expect(result.messageIDs == [1, 2])
        #expect(result.text.contains(subject.text!))
        #expect(result.text.contains(acknowledgement.text!))
        #expect(!result.text.contains("noodles"))
        #expect(!result.text.contains("cancelled"))
    }

    @Test func explicitRepliesRetainTheirOriginalAcrossDays() {
        let original = message(1, "Should we order the blue cabinets?")
        let reply = message(2, "Yes, let's do that.", offset: 5 * 86_400, reply: "message-1")
        let result = MessagePassage.discussion(anchor: reply, messages: [original, reply], handles: [:])
        #expect(result.messageIDs == [1, 2])
    }

    @Test func commonAcknowledgementsDoNotJoinUnrelatedDiscussions() {
        let first = message(1, "Yes sure thanks, that sounds good.")
        let second = message(2, "Thanks, yes that sounds good to me.", offset: 5_400)
        let result = MessagePassage.discussion(anchor: second, messages: [first, second], handles: [:])
        #expect(result.messageIDs == [2])
    }

    @Test func speakerAddressesDoNotBecomeDiscussionIdentifiers() {
        #expect(MessagePassage.indexedIdentifiers("+14155550142: The delivery is reference 482.") == ["482"])
        #expect(MessagePassage.indexedIdentifiers("dana@workshop.example: Let's have lunch.").isEmpty)
        #expect(MessagePassage.indexedIdentifiers("Me: Call +14155550143 about reference 739.") == ["14155550143", "739"])
    }
}
