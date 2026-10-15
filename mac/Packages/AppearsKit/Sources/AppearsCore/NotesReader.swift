import Foundation
import GRDB

/// Reads Apple Notes, read-only, from `NoteStore.sqlite` in Notes' group container. Needs
/// Full Disk Access (and, in the sandboxed engine, a read-only temporary exception).
///
/// Each note's body is a gzipped protobuf: NoteStoreProto.document (2) → note (3) → text (2).
/// Locked notes and notes marked for deletion are skipped.
public enum NotesReader {
    public struct Note: Sendable, Hashable {
        public let identifier: String
        public let title: String
        public let text: String
        public let created: Date
        public let modified: Date
    }

    public static var databaseURL: URL {
        URL(filePath: FileScanner.realHome)
            .appending(path: "Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")
    }

    /// Whether the database can be opened (Full Disk Access granted).
    public static var isReadable: Bool {
        FileManager.default.isReadableFile(atPath: databaseURL.path)
            && (try? FileHandle(forReadingFrom: databaseURL).close()) != nil
    }

    public static func read(from url: URL = databaseURL) throws -> [Note] {
        var config = Configuration()
        config.readonly = true
        config.label = "NoteStore"
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        return try queue.read { db in
            let columns = Set(try db.columns(in: "ZICCLOUDSYNCINGOBJECT").map(\.name))
            func first(_ names: [String]) -> String? { names.first(where: columns.contains) }
            guard let title = first(["ZTITLE1", "ZTITLE"]) else { return [] }
            let modified = first(["ZMODIFICATIONDATE1", "ZMODIFICATIONDATE"]) ?? "NULL"
            let created = first(["ZCREATIONDATE3", "ZCREATIONDATE1", "ZCREATIONDATE"]) ?? "NULL"
            let locked = first(["ZISPASSWORDPROTECTED"]).map { "AND COALESCE(n.\($0), 0) = 0" } ?? ""
            let deleted = first(["ZMARKEDFORDELETION"]).map { "AND COALESCE(n.\($0), 0) = 0" } ?? ""
            let rows = try Row.fetchAll(db, sql: """
                SELECT n.ZIDENTIFIER AS identifier, n.\(title) AS title, n.\(modified) AS modified,
                       n.\(created) AS created, d.ZDATA AS data
                FROM ZICCLOUDSYNCINGOBJECT n JOIN ZICNOTEDATA d ON d.ZNOTE = n.Z_PK
                WHERE n.\(title) IS NOT NULL AND d.ZDATA IS NOT NULL \(locked) \(deleted)
                """)
            return rows.compactMap { row -> Note? in
                guard let identifier = row["identifier"] as String?, let data = row["data"] as Data?,
                      let text = noteText(data) else { return nil }
                let reference = Date(timeIntervalSinceReferenceDate: 0)
                return Note(
                    identifier: identifier, title: row["title"] ?? "Untitled", text: text,
                    created: (row["created"] as Double?).map { Date(timeIntervalSinceReferenceDate: $0) } ?? reference,
                    modified: (row["modified"] as Double?).map { Date(timeIntervalSinceReferenceDate: $0) } ?? reference
                )
            }
        }
    }

    /// The plain text of a note body (gzipped protobuf).
    public static func noteText(_ data: Data) -> String? {
        guard let raw = gunzip(data) ?? (data.first == 0x08 || data.first == 0x12 ? data : nil),
              let document = Protobuf.field(2, in: raw),
              let note = Protobuf.field(3, in: document),
              let text = Protobuf.field(2, in: note) else { return nil }
        return String(data: text, encoding: .utf8)?
            .replacingOccurrences(of: "\u{FFFC}", with: "")  // attachment placeholders
    }

    /// Decompresses gzip with Foundation's raw-DEFLATE decoder, after skipping the header.
    public static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0, bytes.count > index + 2 {  // FEXTRA
            index += 2 + Int(bytes[index]) + Int(bytes[index + 1]) << 8
        }
        if flags & 0x08 != 0 { while index < bytes.count, bytes[index] != 0 { index += 1 }; index += 1 }  // FNAME
        if flags & 0x10 != 0 { while index < bytes.count, bytes[index] != 0 { index += 1 }; index += 1 }  // FCOMMENT
        if flags & 0x02 != 0 { index += 2 }  // FHCRC
        guard index < bytes.count - 8 else { return nil }
        let deflated = Data(bytes[index..<(bytes.count - 8)])
        return try? (deflated as NSData).decompressed(using: .zlib) as Data
    }
}

/// Just enough protobuf to walk to a length-delimited field.
enum Protobuf {
    /// The first length-delimited field with this number at the top level of `data`.
    static func field(_ number: Int, in data: Data) -> Data? {
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            guard let key = varint(bytes, &index) else { return nil }
            let fieldNumber = Int(key >> 3)
            switch key & 7 {
            case 0: guard varint(bytes, &index) != nil else { return nil }
            case 1: index += 8
            case 5: index += 4
            case 2:
                guard let length = varint(bytes, &index), index + Int(length) <= bytes.count else { return nil }
                if fieldNumber == number { return Data(bytes[index..<(index + Int(length))]) }
                index += Int(length)
            default: return nil
            }
        }
        return nil
    }

    static func varint(_ bytes: [UInt8], _ index: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }
}
