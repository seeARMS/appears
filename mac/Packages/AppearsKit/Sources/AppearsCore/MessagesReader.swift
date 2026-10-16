import AppearsMessages
import CryptoKit
import Foundation

/// Reads Messages directly, read-only. Nothing here writes to Messages or uses the network.
public struct MessagesReader: Sendable {
    public let database: ChatDatabase

    public init(url: URL = ChatDatabase.defaultURL) { database = ChatDatabase(url: url) }

    public var isReadable: Bool {
        if case .success = database.checkAccess() { return true }
        return false
    }

    struct Entry {
        var item: Item
        var signature: String
    }

    func entries(for message: Message, chat: Chat?, settings: SourceSettings) -> [Entry] {
        guard message.isSearchable,
              !settings.excludes.contains(where: { database.url.path == $0 || database.url.path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) else { return [] }
        let title = chat?.displayName ?? chat?.participants.map(\.address).joined(separator: ", ").nonEmpty ?? "Messages"
        let reference = MessageReference(rowID: message.rowID, guid: message.guid, chatID: message.chatID,
                                         conversationURL: chat.flatMap(MessagesLink.url))
        let date = max(message.date, message.editedAt ?? .distantPast)
        let base = "\(message.guid)|\(message.handleID)|\(message.isFromMe)|\(title)|\(date.timeIntervalSince1970)|\(message.text ?? "")"
        var result: [Entry] = []
        if let text = message.text, !settings.excludedKinds.contains(.message) {
            let item = Item(source: .messages, path: Self.path(message.rowID), kind: .message,
                            title: title, size: Int64(text.utf8.count), created: message.date, modified: date,
                            lastUsed: nil, message: reference)
            result.append(Entry(item: item, signature: Self.digest(base)))
        }
        if !settings.excludedKinds.contains(.image) {
            for attachment in message.attachments where attachment.isIndexableImage {
                guard let url = localPhoto(attachment),
                      !settings.excludes.contains(where: { url.path == $0 || url.path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }),
                      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let bytes = attributes[.size] as? Int64, bytes <= FileScanner.maxSize(.image) else { continue }
                var photoReference = reference
                photoReference.attachmentPath = url.path
                let item = Item(source: .messages, path: Self.path(message.rowID) + ":photo:\(attachment.guid)", kind: .image,
                                title: "Photo · \(title)", size: bytes, created: message.date, modified: date,
                                lastUsed: nil, message: photoReference)
                let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                result.append(Entry(item: item, signature: Self.digest("\(base)|\(attachment.guid)|\(url.path)|\(bytes)|\(modified)")))
            }
        }
        return result
    }

    /// Metadata checks don't read iCloud placeholders or request downloads.
    private func localPhoto(_ attachment: Attachment) -> URL? {
        guard let url = attachment.fileURL?.standardizedFileURL,
              url.path.hasPrefix(database.url.deletingLastPathComponent().appending(path: "Attachments").path + "/"),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isRegularFile == true else { return nil }
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current,
           values.ubiquitousItemDownloadingStatus != .downloaded { return nil }
        return url
    }

    /// Text-only indexing batches share one database read. Photos retain their file
    /// verification and extraction path below.
    func texts(for items: [Item], handles: [Int64: Handle]) throws -> [Int64: String] {
        let contexts = try database.messagesWithThreads(rowIDs: items.compactMap { $0.message?.rowID }, before: 5, after: 2)
        var result: [Int64: String] = [:]
        for item in items {
            guard item.kind == .message, let reference = item.message,
                  let context = contexts[reference.rowID], context.message.guid == reference.guid,
                  context.message.isSearchable else { continue }
            result[item.id] = Self.context(for: context.message, thread: context.thread, handles: handles)
        }
        return result
    }

    func extraction(for item: Item, handles: [Int64: Handle]) async -> Extraction? {
        guard let reference = item.message,
              let message = try? database.message(rowID: reference.rowID), message.guid == reference.guid,
              message.isSearchable else { return nil }
        let thread = (try? database.thread(around: message, before: 5, after: 2)) ?? [message]
        let document = Self.context(for: message, thread: thread, handles: handles)
        if item.kind == .image {
            guard let path = reference.attachmentPath,
                  message.attachments.contains(where: { $0.isIndexableImage && localPhoto($0)?.path == path }) else { return nil }
            var file = item
            file.source = .file
            file.path = path
            guard var extraction = await Extractor.extract(file) else { return nil }
            if thread.contains(where: { $0.isSearchable && $0.text != nil }) {
                extraction.texts.append((.chunk(0), document))
            }
            return extraction
        }
        var extraction = Extraction()
        extraction.texts = [(.whole, document)]
        return extraction
    }

    /// A bounded conversation around an anchor, retaining the anchor even when it is long.
    static func context(for anchor: Message, thread: [Message], handles: [Int64: Handle]) -> String {
        func line(_ message: Message, limit: Int) -> String {
            let speaker = message.isFromMe ? "Me" : handles[message.handleID]?.address ?? "Sender"
            let words = message.text ?? (message.attachments.contains(where: \.isIndexableImage) ? "[photo]" : "[attachment]")
            return "\(speaker): \(String(words.prefix(limit)))"
        }
        let usable = thread.filter { $0.isSearchable && abs($0.date.timeIntervalSince(anchor.date)) <= 30 * 60 }
        var lines = usable.map { ($0.rowID, line($0, limit: $0.rowID == anchor.rowID ? 1_200 : 280)) }
        if !lines.contains(where: { $0.0 == anchor.rowID }) { lines.append((anchor.rowID, line(anchor, limit: 1_200))) }
        while lines.map(\.1).joined(separator: "\n").count > 1_600, lines.count > 1 {
            if lines.first?.0 != anchor.rowID { lines.removeFirst() } else { lines.removeLast() }
        }
        return lines.map(\.1).joined(separator: "\n")
    }

    static func path(_ rowID: Int64) -> String { "messages:\(rowID)" }
    private static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
