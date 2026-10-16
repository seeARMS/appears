import Foundation

/// A phone number or email address that messages come from, as stored in chat.db's `handle` table.
public struct Handle: Sendable, Hashable, Identifiable {
    public var id: Int64 { rowID }
    public let rowID: Int64
    /// The phone number (`+14155550142`) or email address.
    public let address: String
    /// "iMessage", "SMS" or "RCS".
    public let service: String?

    public init(rowID: Int64, address: String, service: String?) {
        self.rowID = rowID
        self.address = address
        self.service = service
    }
}

/// A conversation: one-to-one or group.
public struct Chat: Sendable, Hashable, Identifiable {
    public var id: Int64 { rowID }
    public let rowID: Int64
    /// For example `iMessage;-;+14155550142` (one-to-one) or `iMessage;+;chat1234` (group).
    public let guid: String
    /// The other person's address for one-to-one chats, or a `chat…` id for groups.
    public let identifier: String
    /// The group name, if someone set one.
    public let displayName: String?
    public let service: String?
    /// chat.db's `style`: 43 for groups, 45 for one-to-one.
    public let style: Int
    public let participants: [Handle]

    public init(
        rowID: Int64, guid: String, identifier: String, displayName: String?,
        service: String?, style: Int, participants: [Handle]
    ) {
        self.rowID = rowID
        self.guid = guid
        self.identifier = identifier
        self.displayName = displayName
        self.service = service
        self.style = style
        self.participants = participants
    }

    public var isGroup: Bool { style == 43 || participants.count > 1 }
}

/// A file attached to a message.
public struct Attachment: Sendable, Hashable, Identifiable {
    public var id: Int64 { rowID }
    public let rowID: Int64
    public let guid: String
    /// The path as Messages stores it, usually starting with `~/Library/Messages/Attachments/`.
    public let path: String?
    public let mimeType: String?
    public let uti: String?
    /// The original file name, like `IMG_1234.HEIC`.
    public let transferName: String?
    public let totalBytes: Int64
    public let isSticker: Bool
    public let isHidden: Bool

    public init(
        rowID: Int64, guid: String, path: String?, mimeType: String?, uti: String?,
        transferName: String?, totalBytes: Int64, isSticker: Bool, isHidden: Bool
    ) {
        self.rowID = rowID
        self.guid = guid
        self.path = path
        self.mimeType = mimeType
        self.uti = uti
        self.transferName = transferName
        self.totalBytes = totalBytes
        self.isSticker = isSticker
        self.isHidden = isHidden
    }

    /// The file on disk, with `~` expanded to the real home folder (not a sandbox container).
    public var fileURL: URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("~/") {
            return URL(filePath: RealHome.path).appending(path: String(path.dropFirst(2)))
        }
        return URL(filePath: path)
    }

    /// Whether the file is still on disk. With Messages in iCloud and "Optimize Storage",
    /// older attachments are often only in iCloud.
    public var isOnDisk: Bool {
        guard let fileURL else { return false }
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    private static let imageUTIs: Set<String> = [
        "public.heic", "public.heif", "public.jpeg", "public.png", "public.tiff",
        "com.compuserve.gif", "org.webmproject.webp", "public.webp",
    ]

    /// A still image we can index: photos and screenshots, not stickers or Memoji.
    public var isIndexableImage: Bool {
        guard !isSticker, !isHidden else { return false }
        if let mimeType, mimeType.hasPrefix("image/") { return true }
        if let uti, Self.imageUTIs.contains(uti) { return true }
        return false
    }
}

/// One message. `text` is already decoded from `attributedBody` when `message.text` is empty.
public struct Message: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// A normal message.
        case normal
        /// A tapback or emoji reaction to another message.
        case reaction
        /// A group event: someone joined, left, renamed the group or changed its photo.
        case groupEvent
    }

    public var id: Int64 { rowID }
    public let rowID: Int64
    public let guid: String
    public let chatID: Int64
    /// The sender's handle for incoming messages. For your own messages in one-to-one chats
    /// chat.db stores the other person here; in groups it's 0.
    public let handleID: Int64
    public let isFromMe: Bool
    public let date: Date
    /// The message's words, with attachment placeholders removed. Nil when there are none.
    public let text: String?
    public let service: String?
    public let editedAt: Date?
    public let isRetracted: Bool
    public let kind: Kind
    public var attachments: [Attachment]

    public init(
        rowID: Int64, guid: String, chatID: Int64, handleID: Int64, isFromMe: Bool, date: Date,
        text: String?, service: String?, editedAt: Date?, isRetracted: Bool, kind: Kind,
        attachments: [Attachment]
    ) {
        self.rowID = rowID
        self.guid = guid
        self.chatID = chatID
        self.handleID = handleID
        self.isFromMe = isFromMe
        self.date = date
        self.text = text
        self.service = service
        self.editedAt = editedAt
        self.isRetracted = isRetracted
        self.kind = kind
        self.attachments = attachments
    }

    /// Worth indexing: a normal message that wasn't unsent.
    public var isSearchable: Bool { kind == .normal && !isRetracted }
}

/// The user's real home folder. Inside the App Sandbox, `NSHomeDirectory()` and
/// `homeDirectoryForCurrentUser` point at the app's container, not `/Users/<name>`.
public enum RealHome {
    public static let path: String = {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }()
}
