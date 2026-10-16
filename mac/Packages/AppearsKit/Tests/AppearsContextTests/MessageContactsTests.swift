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
}
