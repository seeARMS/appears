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
    // Whole seconds survive chat.db's Int64-nanosecond conversion exactly.
    let old = Date(timeIntervalSince1970: 1_700_000_000)

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
    var documentPriorities: [TaskPriority] = []
    var blocked = false
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private let hashing = HashingEmbedder(dimension: 768)

    init(blocked: Bool = false) { self.blocked = blocked }

    func embed(queries: [String]) async throws -> [[Float]] { try await hashing.embed(queries: queries) }
    func embed(documents: [EmbeddingDocument]) async throws -> [[Float]] {
        documentBatches.append(documents.count)
        documentPriorities.append(Task.currentPriority)
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
        #expect(address.openURL?.absoluteString == "sms://open?message-guid=message-2")
        #expect(address.modified == fixture.old.addingTimeInterval(60))
        #expect(try store.item(path: "messages:7")?.modified.timeIntervalSinceNow ?? -1 > -60)
        let photo = try #require(try store.item(path: "messages:3:photo:photo-1"))
        #expect(photo.kind == .image && photo.source == .messages)
        #expect(photo.fileURL == fixture.photo)
        #expect(photo.openURL == fixture.photo)
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

    @Test func opensOldGroupMessagesAtTheirGUID() async throws {
        let fixture = try MessageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let guid = "583F1690-5F4F-4861-BC8B-7245BAA69743"
        try await fixture.database.write { db in
            try db.execute(sql: "UPDATE chat SET style = 43, chat_identifier = 'chat-kitchen', guid = 'iMessage;+;chat-kitchen'")
            try db.execute(sql: "UPDATE message SET guid = ? WHERE ROWID = 1", arguments: [guid])
        }
        let indexer = try fixture.makeIndexer()
        try await indexer.scanMessages()
        let store = await indexer.store
        let item = try #require(try store.item(path: "messages:1"))
        #expect(item.created == fixture.old)
        #expect(item.message?.conversationURL == nil)
        #expect(item.openURL?.absoluteString == "sms://open?message-guid=\(guid)")
    }

    @Test func removedMessagePhotoFallsBackToItsSourceMessage() async throws {
        let fixture = try MessageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let indexer = try fixture.makeIndexer()
        try await indexer.scanMessages()
        let store = await indexer.store
        let photo = try #require(try store.item(path: "messages:3:photo:photo-1"))
        #expect(photo.openURL == fixture.photo)
        try FileManager.default.removeItem(at: fixture.photo)
        #expect(photo.openURL == photo.messageURL)
        #expect(photo.openURL?.absoluteString == "sms://open?message-guid=message-3")
    }

    @Test func messageLinksEncodeTheGUIDAsOneQueryValue() throws {
        let guid = "made-up&body=example?#fragment"
        let url = try #require(MessagesLink.url(messageGUID: guid))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "sms")
        #expect(components.host == "open")
        #expect(components.queryItems == [URLQueryItem(name: "message-guid", value: guid)])
        #expect(components.fragment == nil)
        #expect(MessagesLink.url(messageGUID: "") == nil)
        #expect(MessagesLink.url(messageGUID: " \n") == nil)
    }

    @Test func missingMessageGUIDFallsBackToConversationOrMessages() throws {
        let conversation = try #require(URL(string: "imessage://+14155550142"))
        var item = Item(source: .messages, path: "messages:1", kind: .message, title: "Kitchen crew", size: 0,
                        created: .distantPast, modified: .distantPast, lastUsed: nil,
                        message: MessageReference(rowID: 1, guid: "", chatID: 1, conversationURL: conversation))
        #expect(item.openURL == conversation)
        item.message?.conversationURL = nil
        #expect(item.openURL == URL(filePath: "/System/Applications/Messages.app"))
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

    @Test func threadSeekPreservesTimestampTiesAndChatBoundaries() throws {
        let fixture = try MessageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let date = fixture.old.addingTimeInterval(600)
        for id in Int64(8)...14 {
            try fixture.add(id, text: "Kitchen message \(id).", date: date)
        }
        // The interleaved chat must never enter the anchor's context.
        try fixture.database.write { db in
            try db.execute(sql: "UPDATE chat_message_join SET chat_id = 2 WHERE message_id IN (9, 12)")
            try db.execute(sql: "CREATE INDEX chat_message_date ON chat_message_join(chat_id, message_date, message_id)")
        }
        let database = ChatDatabase(url: fixture.url)
        let anchor = try #require(try database.message(rowID: 11))
        let thread = try database.thread(around: anchor, before: 3, after: 2)
        #expect(thread.map(\.rowID) == [6, 8, 10, 11, 13, 14])
        #expect(try database.thread(around: anchor, before: 0, after: 0).map(\.rowID) == [11])
        let first = try #require(try database.message(rowID: 1))
        #expect(try database.thread(around: first, before: 5, after: 2).map(\.rowID) == [1, 2, 3])
        let last = try #require(try database.message(rowID: 7))
        #expect(try database.thread(around: last, before: 2, after: 5).map(\.rowID) == [13, 14, 7])
        let contexts = try database.messagesWithThreads(rowIDs: [1, 7, 11, 999], before: 3, after: 2)
        #expect(Set(contexts.keys) == [1, 7, 11])
        for (rowID, context) in contexts {
            #expect(try database.message(rowID: rowID) == context.message)
            #expect(try database.thread(around: context.message, before: 3, after: 2) == context.thread)
        }
        #expect(try database.messagesWithThreads(rowIDs: [], before: 3, after: 2).isEmpty)
    }

    @Test func batchTextMatchesIndividualExtractionAndRejectsUnsentMessages() async throws {
        let fixture = try MessageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let indexer = try fixture.makeIndexer()
        try await indexer.scanMessages()
        let store = await indexer.store
        let items = try store.pending(limit: 16)
        let reader = MessagesReader(url: fixture.url)
        let handles = try reader.database.handles()
        let original = try Data(contentsOf: fixture.url)
        let texts = try reader.texts(for: items, handles: handles)
        #expect(texts.count == 3)
        for item in items where item.kind == .message {
            #expect(await reader.extraction(for: item, handles: handles)?.texts.first?.text == texts[item.id])
        }
        #expect(try Data(contentsOf: fixture.url) == original)
        let unsent = try #require(items.first { $0.path == "messages:2" })
        try await fixture.database.write { db in
            try db.execute(sql: "UPDATE message SET date_retracted = 1 WHERE ROWID = 2")
        }
        #expect(try reader.texts(for: items, handles: handles)[unsent.id] == nil)
    }

    @Test func engineKeepsIndexingPriorityWhenCalledFromFileEvents() async throws {
        let fixture = try MessageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let embedder = MessageEmbedder()
        let settings = SourceSettings(notes: false, messages: false, homeOverride: fixture.folder.path)
        let engine = try Engine(folder: fixture.folder.appending(path: "Appears"), embedder: embedder, settings: settings)
        await engine.indexer.setPoliteness(false)
        let url = fixture.folder.appending(path: "priority.txt")
        try "Made-up kitchen permit K-2291.".write(to: url, atomically: true, encoding: .utf8)
        let item = try #require(FileScanner(settings: settings).item(at: url))
        try engine.store.record(item, signature: FileScanner.signature(item))
        // Waiting on a Task's value would raise its priority to the test's priority.
        await withCheckedContinuation { continuation in
            Task.detached(priority: .utility) {
                await engine.indexPending()
                continuation.resume()
            }
        }
        let priorities = await embedder.documentPriorities
        #expect(priorities.count == 1)
        #expect(priorities.allSatisfy { $0.rawValue >= TaskPriority.medium.rawValue })
        #expect(try engine.store.counts().waiting == 0)
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

    @Test func photoContextEditsCannotCommitOlderPreparedText() async throws {
        let fixture = try MessageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let embedder = MessageEmbedder(blocked: true)
        let indexer = try fixture.makeIndexer(embedder: embedder, settings: SourceSettings(excludedKinds: [.message]))
        let store = await indexer.store
        await indexer.setPoliteness(false)
        try await indexer.scanMessages()
        let photo = try #require(try store.pending(limit: 2).first)
        let signature = try store.pendingSignature(itemID: photo.id)
        let run = Task { try await indexer.indexPending() }
        for _ in 0..<1_000 {
            if await embedder.entered { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await embedder.entered)
        try await fixture.database.write { db in
            try db.execute(sql: "UPDATE message SET text = 'Updated permit note K-2291.', date_edited = ? WHERE ROWID = 1",
                           arguments: [AppleDate.chatDBValue(from: Date())])
        }
        try await indexer.scanMessages(full: false)
        #expect(try store.pendingSignature(itemID: photo.id) == signature)
        await embedder.release()
        _ = try await run.value
        let text = try store.units(itemID: photo.id).map(\.unit.text).joined(separator: "\n")
        #expect(text.contains("Updated permit note K-2291"))
        #expect(!text.contains("contractor's kitchen remodel quote"))
        #expect(await embedder.documentBatches.count == 2)
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

    @Test func searchExpansionDoesNotRestoreAnUnsentMessageFromTheStaleIndex() async throws {
        let fixture = try MessageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let embedder = HashingEmbedder()
        let indexer = try fixture.makeIndexer(embedder: embedder)
        try await indexer.scanMessages()
        _ = try await indexer.indexPending()
        try await fixture.database.write { db in
            try db.execute(sql: "UPDATE message SET date_retracted = 1 WHERE ROWID = 1")
        }
        let search = await Search(recall: Recall(store: indexer.store, vectors: indexer.vectors, embedder: embedder),
                                  messages: MessagesReader(url: fixture.url))
        let response = try await search.run(SearchRequest(text: "contractor kitchen quote"), sources: SourceSettings(excludedKinds: [.image]))
        #expect(!response.suggestions.contains { $0.item.message?.rowID == 1 })
        #expect(response.suggestions.allSatisfy { !$0.unit.text.contains("contractor's kitchen remodel quote") })
    }
}
