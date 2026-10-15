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

    public var label: String {
        switch self {
        case .document: "Document"
        case .pdf: "PDF"
        case .image: "Image"
        case .note: "Note"
        }
    }
}

/// Where an item came from.
public enum ItemSource: String, Sendable, Codable, Hashable {
    case file
    case notes
}

/// Something you own: a file, or an Apple Note.
public struct Item: Sendable, Codable, Hashable, Identifiable {
    public var id: Int64
    public var source: ItemSource
    /// A file's path, or `notes:<identifier>` for a note.
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

    public init(
        id: Int64 = 0, source: ItemSource, path: String, kind: ItemKind, title: String, size: Int64,
        created: Date, modified: Date, lastUsed: Date?, metadataOnly: Bool = false
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
    }

    /// The last time you're known to have touched it.
    public var lastTouched: Date { max(lastUsed ?? .distantPast, modified) }

    /// The folder it's in (empty for notes).
    public var folder: String {
        source == .file ? (path as NSString).deletingLastPathComponent : ""
    }

    /// The URL that opens it: the file, or the note in Notes.
    public var openURL: URL? {
        switch source {
        case .file: URL(filePath: path)
        case .notes: URL(string: "notes://showNote?identifier=\(path.dropFirst("notes:".count))")
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
