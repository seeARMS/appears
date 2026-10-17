import AppearsMessages
import Foundation

/// What a unit's vector was made from. Text and image vectors share one space but score on
/// different scales, so they're searched as separate lists and fused by rank.
public enum UnitKind: Int, Sendable, Codable, Hashable {
    case text = 0
    case image = 1
}

/// What kind of thing an item is, for extraction and for the panel's preview.
public enum ItemKind: String, Sendable, Codable, Hashable, CaseIterable {
    case document
    case pdf
    case image
    case note
    case message

    public var label: String {
        switch self {
        case .document: "Document"
        case .pdf: "PDF"
        case .image: "Image"
        case .note: "Note"
        case .message: "Message"
        }
    }
}

/// Where an item came from.
public enum ItemSource: String, Sendable, Codable, Hashable {
    case file
    case notes
    case messages
}

/// Where a Messages result came from. The index is Appears' own, never another app's index.
public struct MessageReference: Sendable, Codable, Hashable {
    public var rowID: Int64
    public var guid: String
    public var chatID: Int64
    public var conversationURL: URL?
    public var attachmentPath: String?

    public init(rowID: Int64, guid: String, chatID: Int64, conversationURL: URL?, attachmentPath: String? = nil) {
        self.rowID = rowID
        self.guid = guid
        self.chatID = chatID
        self.conversationURL = conversationURL
        self.attachmentPath = attachmentPath
    }
}

/// Something you own: a file, an Apple Note, or a message or photo from Messages.
public struct Item: Sendable, Codable, Hashable, Identifiable {
    public var id: Int64
    public var source: ItemSource
    /// A file path, `notes:<identifier>`, or a stable `messages:<rowid>[:photo:<guid>]` key.
    public var path: String
    public var kind: ItemKind
    public var title: String
    public var size: Int64
    public var created: Date
    public var modified: Date
    /// When you last opened it, from Spotlight or from Appears seeing it on screen.
    public var lastUsed: Date?
    /// Metadata-only: iCloud files that aren't downloaded, indexed by name alone.
    public var metadataOnly: Bool
    public var message: MessageReference?

    public init(
        id: Int64 = 0, source: ItemSource, path: String, kind: ItemKind, title: String, size: Int64,
        created: Date, modified: Date, lastUsed: Date?, metadataOnly: Bool = false, message: MessageReference? = nil
    ) {
        self.id = id
        self.source = source
        self.path = path
        self.kind = kind
        self.title = title
        self.size = size
        self.created = created
        self.modified = modified
        self.lastUsed = lastUsed
        self.metadataOnly = metadataOnly
        self.message = message
    }

    /// The last time you're known to have touched it.
    public var lastTouched: Date { max(lastUsed ?? .distantPast, modified) }

    /// A file's folder or a Messages conversation, for diversity; empty for notes.
    public var folder: String {
        if source == .file { return (path as NSString).deletingLastPathComponent }
        if let message { return "messages:\(message.chatID)" }
        return ""
    }

    /// A local file for thumbnails, Quick Look, dragging and revealing in Finder.
    public var fileURL: URL? {
        if source == .file { return URL(filePath: path) }
        return message?.attachmentPath.map { URL(filePath: $0) }
    }

    /// Opens the original file (including Messages photos), note or specific message.
    /// Derive message links from the stored GUID so existing indexes need no rescan.
    public var openURL: URL? {
        switch source {
        case .file: URL(filePath: path)
        case .notes: URL(string: "notes://showNote?identifier=\(path.dropFirst("notes:".count))")
        case .messages:
            fileURL ?? message.flatMap { MessagesLink.url(messageGUID: $0.guid) }
                ?? message?.conversationURL ?? URL(filePath: "/System/Applications/Messages.app")
        }
    }
}

/// A searchable piece of an item: a chunk of text, a PDF page, or an image.
public struct Unit: Sendable, Codable, Hashable, Identifiable {
    public var id: Int64
    public var itemID: Int64
    public var kind: UnitKind
    /// Which part of the item: a chunk number, or a 1-based PDF page.
    public var locator: Locator
    /// The text for full-text search and for the panel's snippet (OCR text for images).
    public var text: String

    public init(id: Int64 = 0, itemID: Int64 = 0, kind: UnitKind, locator: Locator, text: String) {
        self.id = id
        self.itemID = itemID
        self.kind = kind
        self.locator = locator
        self.text = text
    }
}

public enum Locator: Sendable, Codable, Hashable {
    case whole
    case chunk(Int)
    case page(Int)

    var encoded: String {
        switch self {
        case .whole: ""
        case .chunk(let index): "c\(index)"
        case .page(let page): "p\(page)"
        }
    }

    init(encoded: String) {
        if encoded.hasPrefix("p"), let page = Int(encoded.dropFirst()) {
            self = .page(page)
        } else if encoded.hasPrefix("c"), let chunk = Int(encoded.dropFirst()) {
            self = .chunk(chunk)
        } else {
            self = .whole
        }
    }

    public var page: Int? {
        if case .page(let page) = self { return page }
        return nil
    }
}
