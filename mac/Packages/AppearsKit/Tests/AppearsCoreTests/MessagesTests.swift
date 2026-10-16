import AppearsMessages
import CoreGraphics
import Foundation
import GRDB
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import AppearsCore

/// A tiny, made-up Messages database. No test opens the user's Messages or another app's index.
private struct MessageFixture {
    let folder: URL
    let database: DatabaseQueue
    let url: URL
    let photo: URL
    let latePhoto: URL
    let old = Date().addingTimeInterval(-400 * 86_400)

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "appears-messages-\(UUID().uuidString)")
        let attachments = folder.appending(path: "Attachments")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        url = folder.appending(path: "chat.db")
        photo = attachments.appending(path: "quote.png")
        latePhoto = attachments.appending(path: "later.png")
        database = try DatabaseQueue(path: url.path)
        try Self.writePhoto(photo)
        try database.write { db in
            try db.execute(sql: """
                CREATE TABLE handle (id TEXT, service TEXT);
                CREATE TABLE chat (guid TEXT, chat_identifier TEXT, display_name TEXT, service_name TEXT, style INTEGER);
                CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
                CREATE TABLE message (guid TEXT, text TEXT, attributedBody BLOB, handle_id INTEGER, is_from_me INTEGER,
                    date INTEGER, service TEXT, date_edited INTEGER DEFAULT 0, date_retracted INTEGER DEFAULT 0,
                    item_type INTEGER DEFAULT 0, associated_message_type INTEGER DEFAULT 0, cache_has_attachments INTEGER DEFAULT 0);
                CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER);
                CREATE TABLE attachment (guid TEXT, filename TEXT, mime_type TEXT, uti TEXT, transfer_name TEXT,
                    total_bytes INTEGER, is_sticker INTEGER DEFAULT 0, hide_attachment INTEGER DEFAULT 0);
                CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
                INSERT INTO handle VALUES ('+14155550142', 'iMessage');
                INSERT INTO chat VALUES ('iMessage;-;+14155550142', '+14155550142', 'Kitchen crew', 'iMessage', 45);
                INSERT INTO chat_handle_join VALUES (1, 1);
                """)
        }
        try add(1, text: "Here is the contractor's kitchen remodel quote.", date: old)
        try add(2, text: nil, date: old.addingTimeInterval(60), body: Self.body("The permit office is at 1188 Example St."))
        try add(3, text: nil, date: old.addingTimeInterval(120))
        try add(4, text: "Liked a message", date: old.addingTimeInterval(180))
        try add(5, text: "An unsent secret", date: old.addingTimeInterval(240))
        try add(6, text: "Renamed the group", date: old.addingTimeInterval(300))
        try add(7, text: "Lunch today?", date: Date())
        try database.write { db in
            try db.execute(sql: "UPDATE message SET associated_message_type = 2000 WHERE ROWID = 4")
            try db.execute(sql: "UPDATE message SET date_retracted = 1 WHERE ROWID = 5")
            try db.execute(sql: "UPDATE message SET item_type = 1 WHERE ROWID = 6")
            try db.execute(sql: "UPDATE message SET cache_has_attachments = 1 WHERE ROWID = 3")
            for (index, path, sticker, hidden) in [(1, photo.path, 0, 0), (2, photo.path, 1, 0), (3, photo.path, 0, 1), (4, latePhoto.path, 0, 0)] {
                try db.execute(sql: "INSERT INTO attachment (ROWID, guid, filename, mime_type, uti, transfer_name, total_bytes, is_sticker, hide_attachment) VALUES (?, ?, ?, 'image/png', 'public.png', 'quote.png', 100, ?, ?)",
                               arguments: [index, "photo-\(index)", path, sticker, hidden])
                try db.execute(sql: "INSERT INTO message_attachment_join VALUES (3, ?)", arguments: [index])
            }
        }
    }

    func add(_ id: Int64, text: String?, date: Date, body: Data? = nil) throws {
        try database.write { db in
            let timestamp = AppleDate.chatDBValue(from: date)
            try db.execute(sql: "INSERT INTO message (ROWID, guid, text, attributedBody, handle_id, is_from_me, date, service) VALUES (?, ?, ?, ?, 1, 0, ?, 'iMessage')",
                           arguments: [id, "message-\(id)", text, body, timestamp])
            try db.execute(sql: "INSERT INTO chat_message_join VALUES (1, ?, ?)", arguments: [id, timestamp])
        }
    }

    func makeIndexer(embedder: any Embedder = HashingEmbedder(), settings: SourceSettings = SourceSettings()) throws -> Indexer {
        let store = try IndexStore(url: folder.appending(path: "Appears/index.sqlite"))
        return Indexer(store: store, vectors: VectorIndex(dimension: embedder.dimension), embedder: embedder,
                       settings: settings, messagesURL: url)
    }

    // The NSString portion of a typedstream archive, with a two-byte length.
    static func body(_ text: String) -> Data {
        let bytes = Array(text.utf8)
        return Data(Array("NSString".utf8) + [1, 0x94, 0x84, 1, 43, 0x81, UInt8(bytes.count & 255), UInt8(bytes.count >> 8)] + bytes)
    }

    static func writePhoto(_ url: URL) throws {
        let pixels = Data(repeating: 127, count: 400 * 300 * 4)
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(CGImage(width: 400, height: 300, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 400 * 4,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}

/// Records that photos reach the image encoder even when OCR finds no text.
private actor MessageEmbedder: Embedder {
    nonisolated let modelID = "messages-test"
    nonisolated let dimension = 768
    nonisolated let supportsImages = true
    var imageCount = 0
    var documentBatches: [Int] = []
    var blocked = false
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private let hashing = HashingEmbedder(dimension: 768)

    init(blocked: Bool = false) { self.blocked = blocked }

    func embed(queries: [String]) async throws -> [[Float]] { try await hashing.embed(queries: queries) }
    func embed(documents: [EmbeddingDocument]) async throws -> [[Float]] {
        documentBatches.append(documents.count)
        entered = true
        if blocked { await withCheckedContinuation { continuation = $0 } }
        return try await hashing.embed(documents: documents)
    }
    func embed(images: [CGImage]) async throws -> [[Float]] {
        imageCount += images.count
        return try await hashing.embed(queries: images.map { _ in "contractor kitchen remodel quote" })
    }
    func release() { blocked = false; continuation?.resume(); continuation = nil }
}

@Suite struct MessagesTests {
    @Test func upgradesSettingsWithoutLosingExclusions() throws {
        let old = Data(#"{"includes":["/Volumes/Photos"],"excludes":["/private"],"excludedKinds":["pdf"],"notes":false}"#.utf8)
        var settings = try JSONDecoder().decode(SourceSettings.self, from: old)
        #expect(settings.messages)
        #expect(!settings.notes)
        #expect(settings.includes == ["/Volumes/Photos"])
        #expect(settings.excludes == ["/private"])
        #expect(settings.excludedKinds == [.pdf])
        settings.messages = false
        #expect(try !JSONDecoder().decode(SourceSettings.self, from: JSONEncoder().encode(settings)).messages)
    }

    @Test func indexesDirectlyWithConversationContextAndPhotoVectors() async throws {
        let fixture = try MessageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let embedder = MessageEmbedder()
        let indexer = try fixture.makeIndexer(embedder: embedder)
        let store = await indexer.store
        let vectors = await indexer.vectors
        await indexer.setPoliteness(false)
        let original = try Data(contentsOf: fixture.url)
        #expect(try await indexer.scanMessages() == 4)
        #expect(try await indexer.indexPending() == 4)
        #expect(await embedder.imageCount == 1)
        #expect(await embedder.documentBatches.contains(3))
        #expect(try Data(contentsOf: fixture.url) == original)
        let address = try #require(try store.item(path: "messages:2"))
        let text = try #require(try store.units(itemID: address.id).first?.unit.text)
        #expect(text.contains("kitchen remodel quote"))
        #expect(text.contains("1188 Example St"))
        #expect(!text.contains("Lunch today"))
        #expect(address.openURL?.scheme == "imessage")
        #expect(address.modified == fixture.old.addingTimeInterval(60))
        #expect(try store.item(path: "messages:7")?.modified.timeIntervalSinceNow ?? -1 > -60)
        let photo = try #require(try store.item(path: "messages:3:photo:photo-1"))
        #expect(photo.kind == .image && photo.source == .messages)
        #expect(photo.fileURL == fixture.photo)
        #expect(try store.units(itemID: photo.id).contains { $0.unit.kind == .image })
        #expect(try store.item(path: "messages:4") == nil)
        #expect(try store.item(path: "messages:5") == nil)
        #expect(try store.item(path: "messages:6") == nil)
        let recall = Recall(store: store, vectors: vectors, embedder: embedder)
        let response = try await recall.run(RecallRequest(context: .text("contractor kitchen remodel quote"), trigger: .pull))
        #expect(response.suggestions.contains { $0.item.id == photo.id })
        // A second full scan does no embedding work for unchanged content.
        try await indexer.scanMessages()
        #expect(try await indexer.indexPending() == 0)
    }

    @Test func switchesOffBothSourcesAndCanRebuild() async throws {
        let fixture = try MessageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let indexer = try fixture.makeIndexer()
        let store = await indexer.store
        let vectors = await indexer.vectors
        await indexer.setPoliteness(false)
        try await indexer.scanMessages()
        try await indexer.indexPending()
        try await indexer.update(settings: SourceSettings(messages: false))
        #expect(try store.counts().items == 0)
        #expect(try store.counts().units == 0)
        #expect(vectors.count == 0)
        #expect(vectors.search([Float](repeating: 0, count: 256), kind: .text, limit: 10).isEmpty)
        #expect(try await indexer.scanMessages() == 0)
        try await indexer.update(settings: SourceSettings())
        #expect(try await indexer.scanMessages(full: false) == 4)
        #expect(try await indexer.indexPending() == 4)
    }

    @Test func reconcilesEditsDeletionsUnsendsAndLatePhotos() async throws {
        let fixture = try MessageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let indexer = try fixture.makeIndexer()
        let store = await indexer.store
        await indexer.setPoliteness(false)
        try await indexer.scanMessages()
        try await indexer.indexPending()
        try await fixture.database.write { db in
            try db.execute(sql: "UPDATE message SET text = 'The revised quote is $4200.', date_edited = ? WHERE ROWID = 1",
                           arguments: [AppleDate.chatDBValue(from: Date())])
            try db.execute(sql: "UPDATE message SET date_retracted = ? WHERE ROWID = 2", arguments: [AppleDate.chatDBValue(from: Date())])
        }
        try await indexer.scanMessages(full: false)
        try await indexer.indexPending()
        #expect(try store.item(path: "messages:2") == nil)
        let edited = try #require(try store.item(path: "messages:1"))
        #expect(try store.units(itemID: edited.id).first?.unit.text.contains("$4200") == true)
        #expect(try store.units(itemID: edited.id).allSatisfy { !$0.unit.text.contains("1188 Example St") })
        try MessageFixture.writePhoto(fixture.latePhoto)
        try await fixture.database.write { db in try db.execute(sql: "DELETE FROM message WHERE ROWID = 1") }
        try await indexer.scanMessages()
        try await indexer.indexPending()
        #expect(try store.item(path: "messages:1") == nil)
        #expect(try store.item(path: "messages:3:photo:photo-4") != nil)
        let photo = try #require(try store.item(path: "messages:3:photo:photo-1"))
        #expect(try store.units(itemID: photo.id).allSatisfy { !$0.unit.text.contains("$4200") })
        try FileManager.default.removeItem(at: fixture.photo)
        try await indexer.scanMessages()
        #expect(try store.item(path: "messages:3:photo:photo-1") == nil)
    }

    @Test func newMessagesRefreshNeighbourContext() async throws {
        let fixture = try MessageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let indexer = try fixture.makeIndexer()
        let store = await indexer.store
        await indexer.setPoliteness(false)
        try await indexer.scanMessages()
        try await indexer.indexPending()
        try fixture.add(8, text: "The permit number is K-2291.", date: fixture.old.addingTimeInterval(90))
        try await indexer.scanMessages(full: false)
        try await indexer.indexPending()
        let neighbour = try #require(try store.item(path: "messages:2"))
        #expect(try store.units(itemID: neighbour.id).first?.unit.text.contains("K-2291") == true)
    }

    @Test func respectsDemoModeAndPhotoExclusions() async throws {
        let fixture = try MessageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let indexer = try fixture.makeIndexer(settings: SourceSettings(homeOverride: fixture.folder.path))
        let store = await indexer.store
        #expect(try await indexer.scanMessages() == 0)
        try await indexer.update(settings: SourceSettings(excludedKinds: [.image]))
        #expect(try await indexer.scanMessages() == 3)
        #expect(try store.paths(source: .messages).keys.allSatisfy { !$0.contains(":photo:") })
        try await indexer.update(settings: SourceSettings(excludes: [fixture.photo.deletingLastPathComponent().path]))
        #expect(try await indexer.scanMessages() == 3)
    }

    @Test func switchingOffDuringEmbeddingCannotRestoreContent() async throws {
        let fixture = try MessageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let embedder = MessageEmbedder(blocked: true)
        let indexer = try fixture.makeIndexer(embedder: embedder)
        let store = await indexer.store
        await indexer.setPoliteness(false)
        try await indexer.scanMessages()
        let run = Task { try await indexer.indexPending() }
        for _ in 0..<1_000 {
            if await embedder.entered { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await embedder.entered)
        try await indexer.update(settings: SourceSettings(messages: false))
        await embedder.release()
        _ = try await run.value
        #expect(try store.counts().items == 0)
        #expect(try store.counts().units == 0)
    }

    @Test func keepsALongAnchorAndSkipsReactionsInContext() throws {
        let fixture = try MessageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let database = ChatDatabase(url: fixture.url)
        try fixture.add(8, text: String(repeating: "Contractor anchor phrase. ", count: 150), date: fixture.old.addingTimeInterval(200))
        let anchor = try #require(try database.message(rowID: 8))
        let text = MessagesReader.context(for: anchor, thread: try database.thread(around: anchor, before: 5, after: 2), handles: try database.handles())
        #expect(text.count <= 1_600)
        #expect(text.contains("Contractor anchor phrase"))
        #expect(!text.contains("Liked a message"))
        #expect(!text.contains("unsent secret"))
    }

    @Test func removesPersistedMessagesWhenStartingWithSourceOff() async throws {
        let fixture = try MessageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let indexer = try fixture.makeIndexer()
        let store = await indexer.store
        // Match the engine's model so this tests source cleanup, rather than a model reset.
        try store.setMeta("model_id", HashingEmbedder().modelID)
        try await indexer.scanMessages()
        #expect(try store.counts().items == 4)
        let engine = try Engine(folder: fixture.folder.appending(path: "Appears"), embedder: HashingEmbedder(), settings: SourceSettings(messages: false))
        #expect(try engine.store.counts().items == 0)
        #expect(engine.vectors.count == 0)
    }
}
