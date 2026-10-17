import Foundation
import GRDB

/// Read-only access to Messages' `chat.db`.
///
/// Every call opens its own read-only connection and closes it before returning. Appears
/// never writes to chat.db and never keeps a connection open while Messages is running.
/// Columns that only exist in some versions of macOS are checked first, so a missing one
/// falls back to a default instead of failing the query.
public struct ChatDatabase: Sendable {
    public let url: URL

    /// `~/Library/Messages/chat.db` in the real home folder (also when sandboxed).
    public static var defaultURL: URL {
        URL(filePath: RealHome.path).appending(path: "Library/Messages/chat.db")
    }

    public init(url: URL = ChatDatabase.defaultURL) {
        self.url = url
    }

    public enum Failure: Error, Equatable {
        /// The file isn't readable: usually Full Disk Access hasn't been granted.
        case notReadable
        case missing
    }

    /// Whether Appears can read chat.db, which takes Full Disk Access.
    public func checkAccess() -> Result<Void, Failure> {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else {
            // Without Full Disk Access, `fileExists` is also false for ~/Library/Messages.
            return .failure(FileManager.default.isReadableFile(atPath: url.deletingLastPathComponent().path) ? .missing : .notReadable)
        }
        do {
            _ = try read { db in try Int64.fetchOne(db, sql: "SELECT count(*) FROM handle") }
            return .success(())
        } catch {
            return .failure(.notReadable)
        }
    }

    /// Opens a read-only connection, runs `body`, and closes the connection.
    public func read<T>(_ body: (Database) throws -> T) throws -> T {
        var config = Configuration()
        config.readonly = true
        config.label = "chat.db"
        // Messages holds write locks briefly; don't wait on them for long.
        config.busyMode = .timeout(2)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA query_only = 1")
        }
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        defer { try? queue.close() }
        return try queue.read(body)
    }

    // MARK: - Queries

    /// Every handle, keyed by ROWID.
    public func handles() throws -> [Int64: Handle] {
        try read { db in try Self.handles(db) }
    }

    /// Every chat with its participants.
    public func chats() throws -> [Chat] {
        try read { db in
            let handles = try Self.handles(db)
            var members: [Int64: [Handle]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT chat_id, handle_id FROM chat_handle_join") {
                let chatID: Int64 = row["chat_id"]
                let handleID: Int64 = row["handle_id"]
                if let handle = handles[handleID] { members[chatID, default: []].append(handle) }
            }
            let schema = try Schema(db)
            let sql = """
                SELECT ROWID, guid, chat_identifier, \(schema.column("display_name", in: "chat", or: "NULL")),
                       service_name, \(schema.column("style", in: "chat", or: "45"))
                FROM chat
                """
            return try Row.fetchAll(db, sql: sql).map { row in
                let rowID: Int64 = row["ROWID"]
                let name: String? = row["display_name"]
                return Chat(
                    rowID: rowID,
                    guid: row["guid"],
                    identifier: row["chat_identifier"] ?? "",
                    displayName: name?.isEmpty == false ? name : nil,
                    service: row["service_name"],
                    style: row["style"] ?? 45,
                    participants: members[rowID] ?? []
                )
            }
        }
    }

    /// How many messages there are, optionally only those with ROWID at or above `rowID`.
    public func messageCount(atOrAbove rowID: Int64 = 0) throws -> Int {
        try read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM message WHERE ROWID >= ?", arguments: [rowID]) ?? 0
        }
    }

    /// How many messages have attachments, optionally only those with ROWID at or above `rowID`.
    public func attachmentMessageCount(atOrAbove rowID: Int64 = 0) throws -> Int {
        try read { db in
            try Int.fetchOne(
                db, sql: "SELECT count(*) FROM message WHERE cache_has_attachments = 1 AND ROWID >= ?",
                arguments: [rowID]
            ) ?? 0
        }
    }

    /// Up to `limit` messages with attachments and ROWID below `rowID`, newest first.
    public func messagesWithAttachments(before rowID: Int64, limit: Int) throws -> [Message] {
        try read { db in
            try Self.fetchMessages(
                db, where: "m.cache_has_attachments = 1 AND m.ROWID < ?", arguments: [rowID],
                order: "m.ROWID DESC", limit: limit
            )
        }
    }

    /// The highest message ROWID, or 0 for an empty database.
    public func maxMessageRowID() throws -> Int64 {
        try read { db in try Int64.fetchOne(db, sql: "SELECT max(ROWID) FROM message") ?? 0 }
    }

    /// Up to `limit` messages with ROWID below `rowID`, newest first. Pass nil to start at the top.
    public func messages(before rowID: Int64?, limit: Int) throws -> [Message] {
        try read { db in
            try Self.fetchMessages(
                db, where: "m.ROWID < ?", arguments: [rowID ?? Int64.max],
                order: "m.ROWID DESC", limit: limit
            )
        }
    }

    /// Up to `limit` messages with ROWID above `rowID`, oldest first.
    public func messages(after rowID: Int64, limit: Int) throws -> [Message] {
        try read { db in
            try Self.fetchMessages(
                db, where: "m.ROWID > ?", arguments: [rowID], order: "m.ROWID ASC", limit: limit
            )
        }
    }

    /// The messages in a chat between two dates, oldest first. Used to build context windows.
    public func messages(inChat chatID: Int64, from start: Date, to end: Date) throws -> [Message] {
        try read { db in
            try Self.fetchMessages(
                db,
                where: "cmj.chat_id = ? AND cmj.message_date BETWEEN ? AND ?",
                arguments: [chatID, AppleDate.chatDBValue(from: start), AppleDate.chatDBValue(from: end)],
                order: "cmj.message_date ASC, m.ROWID ASC", limit: nil
            )
        }
    }

    /// The thread around one message: up to `before` earlier and `after` later messages in its
    /// chat, plus the message itself, oldest first.
    public func thread(around message: Message, before: Int, after: Int) throws -> [Message] {
        try read { db in
            try Self.thread(db, around: message, before: before, after: after, schema: Schema(db))
        }
    }

    /// A batch of anchors and their context, from one short read-only transaction. Reusing
    /// the connection and schema avoids opening two connections for each indexed message.
    public func messagesWithThreads(
        rowIDs: [Int64], before: Int, after: Int, includeReplies: Bool = false
    ) throws -> [Int64: (message: Message, thread: [Message])] {
        guard !rowIDs.isEmpty else { return [:] }
        return try read { db in
            let schema = try Schema(db)
            var result: [Int64: (message: Message, thread: [Message])] = [:]
            for chunk in rowIDs.chunked(into: 500) {
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let anchors = try Self.fetchMessages(
                    db, where: "m.ROWID IN (\(placeholders))", arguments: StatementArguments(chunk),
                    order: "m.ROWID", limit: nil, schema: schema
                )
                for message in anchors {
                    try Task.checkCancellation()
                    var thread = try Self.thread(db, around: message, before: before, after: after, schema: schema)
                    if includeReplies, let guid = message.replyToGUID,
                       let original = try Self.fetchMessages(db, where: "m.guid = ? AND cmj.chat_id = ?",
                            arguments: [guid, message.chatID], order: "m.ROWID", limit: 1, schema: schema).first,
                       !thread.contains(where: { $0.rowID == original.rowID }) {
                        thread.append(original)
                    }
                    result[message.rowID] = (message, thread)
                }
            }
            return result
        }
    }

    /// One message by ROWID.
    public func message(rowID: Int64) throws -> Message? {
        try read { db in
            try Self.fetchMessages(db, where: "m.ROWID = ?", arguments: [rowID], order: "m.ROWID", limit: 1).first
        }
    }

    /// Messages edited after `date`, so their index entries can be refreshed.
    public func messages(editedAfter date: Date) throws -> [Message] {
        try read { db in
            let schema = try Schema(db)
            let columns = ["date_edited", "date_retracted"].filter { schema.has($0, in: "message") }
            guard !columns.isEmpty else { return [] }
            return try Self.fetchMessages(
                db, where: columns.map { "m.\($0) > ?" }.joined(separator: " OR "),
                arguments: StatementArguments(columns.map { _ in AppleDate.chatDBValue(from: date) }),
                order: "m.ROWID ASC", limit: nil
            )
        }
    }

    /// Which of these message ROWIDs still exist, to find deleted messages.
    public func existingMessageRowIDs(in rowIDs: [Int64]) throws -> Set<Int64> {
        guard !rowIDs.isEmpty else { return [] }
        return try read { db in
            var found = Set<Int64>()
            for chunk in rowIDs.chunked(into: 500) {
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let ids = try Int64.fetchAll(
                    db, sql: "SELECT ROWID FROM message WHERE ROWID IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
                found.formUnion(ids)
            }
            return found
        }
    }

    // MARK: - Row mapping

    private static func thread(_ db: Database, around message: Message, before: Int, after: Int, schema: Schema) throws -> [Message] {
        let date = AppleDate.chatDBValue(from: message.date)
        // Seek into Messages' (chat_id, message_date, message_id) index. An OR
        // between dates and ids makes SQLite read and sort the chat's history.
        let earlier = try fetchMessages(
            db, where: "cmj.chat_id = ? AND (cmj.message_date, cmj.message_id) < (?, ?)",
            arguments: [message.chatID, date, message.rowID],
            order: "cmj.message_date DESC, cmj.message_id DESC", limit: before, schema: schema
        )
        let later = try fetchMessages(
            db, where: "cmj.chat_id = ? AND (cmj.message_date, cmj.message_id) >= (?, ?)",
            arguments: [message.chatID, date, message.rowID],
            order: "cmj.message_date ASC, cmj.message_id ASC", limit: after + 1, schema: schema
        )
        return earlier.reversed() + later
    }

    private static func handles(_ db: Database) throws -> [Int64: Handle] {
        var result: [Int64: Handle] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT ROWID, id, service FROM handle") {
            let handle = Handle(rowID: row["ROWID"], address: row["id"] ?? "", service: row["service"])
            result[handle.rowID] = handle
        }
        return result
    }

    private static func fetchMessages(
        _ db: Database, where condition: String, arguments: StatementArguments, order: String, limit: Int?, schema: Schema? = nil
    ) throws -> [Message] {
        let schema = try schema ?? Schema(db)
        let m = { (column: String, fallback: String) in schema.column(column, in: "message", or: fallback, prefix: "m") }
        let sql = """
            SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.handle_id, m.is_from_me, m.date, m.service,
                   \(m("date_edited", "0")), \(m("date_retracted", "0")), \(m("item_type", "0")),
                   \(m("associated_message_type", "0")), \(m("cache_has_attachments", "0")),
                   cmj.chat_id, \(m("thread_originator_guid", "NULL")), \(m("reply_to_guid", "NULL"))
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE \(condition)
            ORDER BY \(order)
            \(limit.map { "LIMIT \($0)" } ?? "")
            """
        var seen = Set<Int64>()
        var messages: [Message] = []
        var withAttachments: [Int64] = []
        for row in try Row.fetchAll(db, sql: sql, arguments: arguments) {
            let rowID: Int64 = row["ROWID"]
            // A message can sit in two chats after chats merge; keep the first.
            guard seen.insert(rowID).inserted else { continue }

            var text: String? = (row["text"] as String?)?.cleanedMessageText
            if text == nil, let body: Data = row["attributedBody"] {
                text = AttributedBody.string(from: body)?.cleanedMessageText
            }
            let itemType: Int = row["item_type"] ?? 0
            let associatedType: Int = row["associated_message_type"] ?? 0
            let kind: Message.Kind =
                itemType != 0 ? .groupEvent : (2000...3999).contains(associatedType) ? .reaction : .normal
            let editedValue: Int64 = row["date_edited"] ?? 0
            let retractedValue: Int64 = row["date_retracted"] ?? 0

            messages.append(Message(
                rowID: rowID,
                guid: row["guid"],
                chatID: row["chat_id"],
                handleID: row["handle_id"] ?? 0,
                isFromMe: (row["is_from_me"] as Int? ?? 0) != 0,
                date: AppleDate.date(fromChatDB: row["date"] ?? 0) ?? .distantPast,
                text: text,
                service: row["service"],
                editedAt: AppleDate.date(fromChatDB: editedValue),
                isRetracted: retractedValue > 0,
                kind: kind,
                attachments: [],
                replyToGUID: (row["thread_originator_guid"] as String? ?? row["reply_to_guid"] as String?)
                    .flatMap { value in value.split(separator: "/").last.map(String.init) }
            ))
            if (row["cache_has_attachments"] as Int? ?? 0) != 0 { withAttachments.append(rowID) }
        }

        let attachments = try fetchAttachments(db, schema: schema, messageRowIDs: withAttachments)
        if !attachments.isEmpty {
            for index in messages.indices {
                messages[index].attachments = attachments[messages[index].rowID] ?? []
            }
        }
        return messages
    }

    private static func fetchAttachments(
        _ db: Database, schema: Schema, messageRowIDs: [Int64]
    ) throws -> [Int64: [Attachment]] {
        guard !messageRowIDs.isEmpty else { return [:] }
        let a = { (column: String, fallback: String) in schema.column(column, in: "attachment", or: fallback, prefix: "a") }
        var result: [Int64: [Attachment]] = [:]
        for chunk in messageRowIDs.chunked(into: 500) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = """
                SELECT maj.message_id, a.ROWID, a.guid, a.filename, a.mime_type, a.uti, a.transfer_name,
                       \(a("total_bytes", "0")), \(a("is_sticker", "0")), \(a("hide_attachment", "0"))
                FROM message_attachment_join maj
                JOIN attachment a ON a.ROWID = maj.attachment_id
                WHERE maj.message_id IN (\(placeholders))
                ORDER BY maj.message_id, a.ROWID
                """
            for row in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(chunk)) {
                let messageID: Int64 = row["message_id"]
                result[messageID, default: []].append(Attachment(
                    rowID: row["ROWID"],
                    guid: row["guid"],
                    path: row["filename"],
                    mimeType: row["mime_type"],
                    uti: row["uti"],
                    transferName: row["transfer_name"],
                    totalBytes: row["total_bytes"] ?? 0,
                    isSticker: (row["is_sticker"] as Int? ?? 0) != 0,
                    isHidden: (row["hide_attachment"] as Int? ?? 0) != 0
                ))
            }
        }
        return result
    }
}

/// The columns each table actually has, since chat.db gains and loses columns between
/// versions of macOS.
private struct Schema {
    private var columns: [String: Set<String>] = [:]

    init(_ db: Database) throws {
        for table in ["message", "attachment", "chat"] {
            columns[table] = Set(try db.columns(in: table).map(\.name))
        }
    }

    func has(_ column: String, in table: String) -> Bool {
        columns[table]?.contains(column) ?? false
    }

    /// `prefix.column` if it exists, otherwise `fallback AS column`.
    func column(_ column: String, in table: String, or fallback: String, prefix: String? = nil) -> String {
        if has(column, in: table) {
            return prefix.map { "\($0).\(column)" } ?? column
        }
        return "\(fallback) AS \(column)"
    }
}

extension Array {
    func chunked(into size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}
