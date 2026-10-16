import AppearsCore
import AppearsMessages
import Contacts
import Foundation

/// Presentation only, in the app. Contact names and photos never enter the engine,
/// embeddings, journal or thumbnail cache on disk.
public struct MessageContacts: Sendable {
    public struct Person: Sendable {
        public var id: String
        public var name: String
        public var addresses: [String]
        public var photo: Data?

        public init(id: String, name: String, addresses: [String], photo: Data? = nil) {
            self.id = id
            self.name = name
            self.addresses = addresses
            self.photo = photo
        }
    }

    public struct Presentation: Sendable {
        public var title: String
        public var initials: String?
        public var photo: Data?
        public var isGroup: Bool
    }

    public enum Access: Sendable { case granted, notAsked, denied }

    public static var access: Access {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    public static func requestAccess() async {
        _ = try? await CNContactStore().requestAccess(for: .contacts)
    }

    private var people: [String: Person] = [:]
    private var ambiguous: Set<String> = []
    private var chats: [Int64: Chat]

    public init(people: [Person] = [], chats: [Chat] = []) {
        self.chats = Dictionary(chats.map { ($0.rowID, $0) }, uniquingKeysWith: { first, _ in first })
        for person in people {
            for address in person.addresses {
                let key = Self.key(address)
                guard !key.isEmpty else { continue }
                if let existing = self.people[key], existing.id != person.id {
                    ambiguous.insert(key)
                } else {
                    self.people[key] = person
                }
            }
        }
    }

    /// Call off the main actor; never requests permission implicitly. Uses the supported
    /// Contacts API, rather than reading Contacts' private database under Full Disk Access.
    public static func load() throws -> Self {
        var people: [Person] = []
        if access == .granted {
            let request = CNContactFetchRequest(keysToFetch: [
                CNContactIdentifierKey as CNKeyDescriptor,
                CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                CNContactOrganizationNameKey as CNKeyDescriptor,
                CNContactNicknameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor,
                CNContactThumbnailImageDataKey as CNKeyDescriptor,
            ])
            try CNContactStore().enumerateContacts(with: request) { contact, _ in
                let name = [CNContactFormatter.string(from: contact, style: .fullName) ?? "",
                            contact.organizationName, contact.nickname]
                    .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
                guard !name.isEmpty else { return }
                people.append(Person(id: contact.identifier, name: name,
                                     addresses: contact.phoneNumbers.map { $0.value.stringValue }
                                        + contact.emailAddresses.map { $0.value as String },
                                     photo: contact.thumbnailImageData))
            }
        }
        return Self(people: people, chats: (try? MessagesReader().database.chats()) ?? [])
    }

    public func presentation(for item: Item) -> Presentation? {
        guard item.source == .messages, let reference = item.message else { return nil }
        let chat = chats[reference.chatID]
        let fallback = item.kind == .image && item.title.hasPrefix("Photo · ") ? String(item.title.dropFirst(8)) : item.title
        let addresses = chat.map { chat in
            chat.participants.isEmpty && !chat.isGroup ? [chat.identifier] : chat.participants.map(\.address)
        } ?? [fallback]
        let resolved = addresses.map { person(for: $0) }
        let group = chat?.isGroup ?? (addresses.count > 1)
        let explicitName = chat?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String
        if let explicitName, !explicitName.isEmpty {
            title = explicitName
        } else {
            let names = zip(addresses, resolved).map { address, person in person?.name ?? address }
            title = names.isEmpty ? fallback : names.joined(separator: ", ")
        }
        let person = group ? nil : resolved.first.flatMap { $0 }
        let initials = person.map { Self.initials($0.name) }
            ?? (group && explicitName?.isEmpty == false ? Self.initials(title) : nil)
        return Presentation(title: item.kind == .image ? "Photo · \(title)" : title,
                            initials: initials, photo: person?.photo, isGroup: group)
    }

    private func person(for address: String) -> Person? {
        let key = Self.key(address)
        return ambiguous.contains(key) ? nil : people[key]
    }

    private static func initials(_ name: String) -> String? {
        let words = name.split(whereSeparator: \.isWhitespace)
        guard let first = words.first?.first else { return nil }
        let last = words.count > 1 ? words.last?.first.map(String.init) ?? "" : ""
        return (String(first) + last).uppercased()
    }

    /// Preserve country codes: matching arbitrary trailing digits can show the wrong
    /// person's name or photo. Only the unambiguous NANP local/+1 variant is collapsed.
    static func key(_ address: String) -> String {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.contains("@") { return value }
        guard !value.isEmpty, value.allSatisfy({ $0.isWhitespace || ($0.isASCII && ($0.isNumber || "+()-.".contains($0))) }) else { return value }
        var digits = value.filter(\.isNumber)
        if value.hasPrefix("00") { digits = String(digits.dropFirst(2)) }
        if !value.hasPrefix("+"), !value.hasPrefix("00"), digits.count == 10 { digits = "1" + digits }
        return digits.isEmpty ? value : "+" + digits
    }
}
