import AppearsCore
import AppearsMessages
import Foundation
import Testing
@testable import AppearsContext

struct MessageContactsTests {
    private let dana = MessageContacts.Person(id: "dana", name: "Dana Ruiz",
        addresses: ["(415) 555-0142", "dana@example.test"], photo: Data([1, 2, 3]))
    private let joan = MessageContacts.Person(id: "joan", name: "Joan Lee", addresses: ["+14155550143"])

    private func chat(_ addresses: [String], name: String? = nil, group: Bool = false) -> Chat {
        Chat(rowID: 12, guid: "made-up-chat", identifier: addresses.first ?? "",
             displayName: name, service: "iMessage", style: group ? 43 : 45,
             participants: addresses.enumerated().map { Handle(rowID: Int64($0.offset), address: $0.element, service: "iMessage") })
    }

    private func item(kind: ItemKind = .message, title: String = "+14155550142") -> Item {
        Item(source: .messages, path: "messages:1", kind: kind, title: title, size: 10,
             created: .distantPast, modified: .distantPast, lastUsed: nil,
             message: MessageReference(rowID: 1, guid: "made-up-message", chatID: 12, conversationURL: nil))
    }

    @Test func resolvesExistingIndexedTitlesWithoutChangingSourceMetadata() throws {
        let original = item()
        let directory = MessageContacts(people: [dana], chats: [chat(["+14155550142"])])
        let result = try #require(directory.presentation(for: original))
        #expect(result.title == "Dana Ruiz")
        #expect(result.initials == "DR")
        #expect(result.photo == dana.photo)
        #expect(!result.isGroup)
        #expect(original.title == "+14155550142")
        #expect(original.message?.guid == "made-up-message")
    }

    @Test func retrievalScopeRequiresAnUnambiguousIdentity() {
        let directory = MessageContacts(people: [dana], chats: [chat(["+14155550142"])])
        #expect(directory.chatIDs(forWindowTitle: "Dana Ruiz") == [12])
        #expect(directory.chatIDs(forWindowTitle: "Dana").isEmpty)
        let second = MessageContacts.Person(id: "another-dana", name: "Dana Ruiz", addresses: ["+14155550144"])
        let otherChat = Chat(rowID: 13, guid: "second-chat", identifier: "+14155550144", displayName: nil,
                             service: "iMessage", style: 45,
                             participants: [Handle(rowID: 3, address: "+14155550144", service: "iMessage")])
        let ambiguous = MessageContacts(people: [dana, second], chats: [chat(["+14155550142"]), otherChat])
        #expect(ambiguous.chatIDs(forWindowTitle: "Dana Ruiz").isEmpty)
        #expect(ambiguous.chatIDs(forWindowTitle: "+14155550144") == [13])
    }

    @Test func normalizesEmailsAndFormattingWithoutDiscardingCountryCodes() {
        #expect(MessageContacts.key(" DANA@Example.Test ") == MessageContacts.key("dana@example.test"))
        #expect(MessageContacts.key("(415) 555-0142") == MessageContacts.key("+1 415-555-0142"))
        #expect(MessageContacts.key("(415)\u{a0}555-0142") == MessageContacts.key("+14155550142"))
        #expect(MessageContacts.key("0014155550142") == MessageContacts.key("+14155550142"))
        #expect(MessageContacts.key("+44 7911 123456") != MessageContacts.key("+1 7911 123456"))
        let directory = MessageContacts(people: [dana], chats: [chat(["DANA@EXAMPLE.TEST"])])
        #expect(directory.presentation(for: item())?.title == "Dana Ruiz")
    }

    @Test func preservesGroupNamesAndNeverUsesOneParticipantsPhotoForAGroup() {
        let named = MessageContacts(people: [dana, joan], chats: [chat(["+14155550142", "+14155550143"], name: "Kitchen crew", group: true)])
        #expect(named.presentation(for: item())?.title == "Kitchen crew")
        #expect(named.presentation(for: item())?.initials == "KC")
        #expect(named.presentation(for: item())?.isGroup == true)
        #expect(named.presentation(for: item())?.photo == nil)
        let unnamed = MessageContacts(people: [dana, joan], chats: [chat(["+14155550142", "+14155550143"], group: true)])
        #expect(unnamed.presentation(for: item())?.title == "Dana Ruiz, Joan Lee")
        // Even one remaining participant is still a group according to chat.db's style.
        let formerGroup = MessageContacts(people: [dana], chats: [chat(["+14155550142"], group: true)])
        #expect(formerGroup.presentation(for: item())?.photo == nil)
    }

    @Test func fallsBackWithoutPermissionOrWhenAnAddressIsUnknownOrAmbiguous() {
        let withoutContacts = MessageContacts(chats: [chat(["+14155550142"])])
        #expect(withoutContacts.presentation(for: item())?.title == "+14155550142")
        #expect(withoutContacts.presentation(for: item())?.photo == nil)
        let collision = MessageContacts.Person(id: "someone-else", name: "Different Person", addresses: ["+14155550142"])
        let ambiguous = MessageContacts(people: [dana, collision], chats: [chat(["+14155550142"])])
        #expect(ambiguous.presentation(for: item())?.title == "+14155550142")
        #expect(ambiguous.presentation(for: item())?.photo == nil)
        #expect(MessageContacts().presentation(for: item(title: "Old group title"))?.title == "Old group title")
        let noChat = MessageContacts(people: [dana])
        #expect(noChat.presentation(for: item())?.title == "Dana Ruiz")
    }

    @Test func labelsAttachedPhotosButLeavesTheirPreviewAndNonMessageItemsAlone() {
        let directory = MessageContacts(people: [dana], chats: [chat(["+14155550142"])])
        var photo = item(kind: .image, title: "Photo · +14155550142")
        photo.message?.attachmentPath = "/made-up/quote.png"
        #expect(directory.presentation(for: photo)?.title == "Photo · Dana Ruiz")
        #expect(photo.fileURL?.path == "/made-up/quote.png")
        var file = photo
        file.source = .file
        #expect(directory.presentation(for: file) == nil)
    }

    private func suggestion(text: String, snippet: String? = nil, item: Item? = nil) -> Suggestion {
        Suggestion(item: item ?? self.item(), unit: Unit(kind: .text, locator: .whole, text: text),
                   reason: "Related", snippet: snippet ?? text.replacingOccurrences(of: "\n", with: " "),
                   score: 1, confidence: 0.8,
                   features: Features(cosine: 0.8, zScore: 5, agreement: true, entityHit: true,
                                      daysSinceTouched: 1, fused: 1, forgotten: 1, novelty: 1))
    }

    @Test func resolvesSpeakersInFlattenedSearchExcerptsAndMultilinePreviews() {
        let directory = MessageContacts(people: [dana, joan])
        let text = "Me: Where is the ladder?\n+14155550142: By the garage.\n+14155550143: Beside the shelves."
        let original = suggestion(text: text)
        #expect(directory.displaySnippet(for: original) == "Me: Where is the ladder? Dana Ruiz: By the garage. Joan Lee: Beside the shelves.")
        #expect(directory.displayText(text, for: original.item) == "Me: Where is the ladder?\nDana Ruiz: By the garage.\nJoan Lee: Beside the shelves.")
        #expect(original.unit.text == text)
        #expect(original.snippet.contains("+14155550142"))
    }

    @Test func preservesBodyNumbersAndHandlesClippedUnicodeExcerpts() {
        let directory = MessageContacts(people: [dana, joan])
        let text = "Me: 🪜 Call +14155550142: ask about the ladder.\n+14155550142: It’s by the garage.\n+14155550143: Thanks!"
        let clipped = suggestion(text: text, snippet: "…the ladder. +14155550142: It’s by the garage. +14155550143: Thanks…")
        #expect(directory.displaySnippet(for: clipped) == "…the ladder. Dana Ruiz: It’s by the garage. Joan Lee: Thanks…")
        let full = directory.displaySnippet(for: suggestion(text: text))
        #expect(full.hasPrefix("Me: 🪜 Call +14155550142: ask about the ladder."))
        #expect(directory.displayText(text, for: item()).hasPrefix("Me: 🪜 Call +14155550142: ask about the ladder."))
        let partialSpeaker = suggestion(text: text, snippet: "…5550142: It’s by the garage.…")
        #expect(directory.displaySnippet(for: partialSpeaker) == partialSpeaker.snippet)
    }

    @Test func leavesUnknownAmbiguousAndNonMessageSpeakersAlone() {
        let collision = MessageContacts.Person(id: "other", name: "Different Person", addresses: dana.addresses)
        let directory = MessageContacts(people: [dana, collision])
        let text = "Me: Where?\n+14155550142: By the garage.\n+14155550149: Thanks."
        let original = suggestion(text: text)
        #expect(directory.displaySnippet(for: original) == original.snippet)
        #expect(MessageContacts().displayText(text, for: item()) == text)
        var note = item()
        note.source = .notes
        #expect(MessageContacts(people: [dana]).displaySnippet(for: suggestion(text: text, item: note)) == original.snippet)
        #expect(MessageContacts(people: [dana]).displayText(text, for: note) == text)
        let email = suggestion(text: "Me: Where?\nDANA@EXAMPLE.TEST: By the garage.")
        #expect(MessageContacts(people: [dana]).displaySnippet(for: email) == "Me: Where? Dana Ruiz: By the garage.")
    }

    @Test func preservesAnswerEmphasisAndClipboardPrivacyAcrossSplitSenderSegments() {
        let directory = MessageContacts(people: [dana, joan])
        let line = MatchedLine(segments: [.init("+1415"), .init("5550142", emphasized: true),
                                         .init(": Gate code: "), .init("1234", emphasized: true),
                                         .init("\n+14155550143: Thanks")], concealed: true)
        let displayed = directory.displayLine(line, for: item())
        #expect(displayed.text == "Dana Ruiz: Gate code: 1234\nJoan Lee: Thanks")
        #expect(displayed.segments.contains(.init("1234", emphasized: true)))
        #expect(displayed.concealed)
        #expect(line.text.hasPrefix("+14155550142:"))
    }
}
