import AppearsMessages
import CoreGraphics
import Foundation
import GRDB
import Testing
@testable import AppearsCore

/// Known semantic vectors deliberately connect phrases without shared keywords. These
/// tests verify provenance, ranking and rendering independently of an embedding model.
struct PassageTestEmbedder: Embedder {
    let modelID = "passage-test"
    let dimension = 3
    let supportsImages = false
    var minimumPassageSimilarity: Double? { 0.70 }
    var preferred = PassageEvidenceTests.answer
    var otherVector: [Float] = [0, 1, 0]
    var onEmbed: (@Sendable () throws -> Void)?
    func embed(queries: [String]) async throws -> [[Float]] {
        queries.map { $0.contains("amplifier") ? [0, 0, 1] : [1, 0, 0] }
    }
    func embed(documents: [EmbeddingDocument]) async throws -> [[Float]] {
        try onEmbed?()
        return documents.map { document in
            if document.text == preferred { return [1, 0, 0] }
            return document.text.contains(preferred) ? [0.95, 0.31225, 0] : otherVector
        }
    }
    func embed(images: [CGImage]) async throws -> [[Float]] { [] }
}

@Suite struct PassageEvidenceTests {
    static let answer = "The parcel courier's relatives run Silverbrook Cellars in Oak Hollow."

    private func prepare(_ fixture: MessageFixture) throws -> (IndexStore, VectorIndex, [Item]) {
        let start = fixture.old.addingTimeInterval(86_400)
        for (offset, text) in ["Was this at your gate?", "Yeah", Self.answer, "We should go.", "There's a small vegetation fire nearby.", "I will look at the map."].enumerated() {
            try fixture.add(Int64(100 + offset), text: text, date: start.addingTimeInterval(Double(offset * 20)))
        }
        let store = try IndexStore(url: fixture.folder.appending(path: "evidence/index.sqlite"))
        let vectors = VectorIndex(dimension: 3)
        let reader = MessagesReader(url: fixture.url)
        let messages = try reader.database.messages(before: nil, limit: 50).filter { $0.rowID >= 100 }
        let handles = try reader.database.handles()
        var items: [Item] = []
        for message in messages {
            let entry = try #require(reader.entries(for: message, chat: nil, settings: SourceSettings()).first)
            let (id, _) = try store.record(entry.item, signature: entry.signature)
            let item = try #require(try store.item(path: MessagesReader.path(message.rowID)))
            let thread = try reader.database.thread(around: message, before: 5, after: 2)
            let text = MessagesReader.context(for: message, thread: thread, handles: handles)
            let vector: [Float] = [0.95, 0.31225, 0]
            let update = try store.replaceUnits(itemID: id, title: item.title, units: [
                (AppearsCore.Unit(kind: .text, locator: .whole, text: text), vector),
            ])
            for unit in update.added { vectors.upsert(id: unit.id, kind: unit.kind, vector: vector) }
            items.append(item)
        }
        return (store, vectors, items)
    }

    @Test func retrievesExactSemanticEvidenceAndCollapsesOverlappingWindows() async throws {
        let fixture = try MessageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let (store, vectors, _) = try prepare(fixture)
        let recall = Recall(store: store, vectors: vectors, embedder: PassageTestEmbedder(), messages: MessagesReader(url: fixture.url))
        for trigger in [Trigger.pull, .ambient] {
            let response = try await recall.run(RecallRequest(context: ContextSnapshot(appName: "Messages", focusedText: "Which winery did the UPS guy recommend?"), trigger: trigger, limit: 10))
            let first = try #require(response.suggestions.first)
            #expect(first.evidence?.text == Self.answer)
            #expect(first.item.message?.rowID == 102)
            #expect(first.item.messageURL?.absoluteString.contains("message-102") == true)
            #expect(response.suggestions.count == 1)
            let evidence = try #require(first.evidence)
            let source = try #require(evidence.sources.first)
            let stored = try await fixture.database.read { db in try String.fetchOne(db, sql: "SELECT text FROM message WHERE ROWID = 102") }
            let original = try #require(stored)
            #expect((original as NSString).substring(with: NSRange(location: source.utf16Location, length: source.utf16Length)) == evidence.text)
            let displayed = SuggestionEvidence(first, terms: ["winery", "UPS", "gate"]).segments.map(\.text).joined()
            #expect(displayed == Self.answer, "Query terms cannot replace the scored evidence with another sentence")
        }
    }

    @Test func hiddenOrUnsentSourcesCannotLeakThroughANeighboursContext() async throws {
        let fixture = try MessageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let (store, vectors, items) = try prepare(fixture)
        let answer = try #require(items.first { $0.message?.rowID == 102 })
        try store.setNeverShow(itemID: answer.id)
        let recall = Recall(store: store, vectors: vectors, embedder: PassageTestEmbedder(), messages: MessagesReader(url: fixture.url))
        let response = try await recall.run(RecallRequest(context: .text("Which winery did the UPS guy recommend?"), trigger: .pull, limit: 10))
        #expect(!response.suggestions.isEmpty)
        #expect(response.suggestions.allSatisfy { $0.evidence?.text.contains(Self.answer) != true })
        #expect(response.suggestions.allSatisfy { !$0.unit.text.contains(Self.answer) },
                "Inline previews must not expose a hidden neighbour from a stale indexed window")
    }

    @Test func unsendWhileScoringDiscardsTheSource() async throws {
        let fixture = try MessageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let (store, vectors, _) = try prepare(fixture)
        let embedder = PassageTestEmbedder(onEmbed: { [database = fixture.database] in
            try database.write { db in try db.execute(sql: "UPDATE message SET date_retracted = 1 WHERE ROWID = 102") }
        })
        let recall = Recall(store: store, vectors: vectors, embedder: embedder, messages: MessagesReader(url: fixture.url))
        let response = try await recall.run(RecallRequest(context: .text("Which winery did the UPS guy recommend?"), trigger: .pull))
        #expect(response.suggestions.isEmpty)
    }

    @Test func unrelatedDraftCannotGainAmbientConfidenceFromTheChat() async throws {
        let fixture = try MessageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let (store, vectors, _) = try prepare(fixture)
        let recall = Recall(store: store, vectors: vectors, embedder: PassageTestEmbedder(), messages: MessagesReader(url: fixture.url))
        let context = ContextSnapshot(appName: "Messages", focusedText: "Did you repair the amplifier?", visibleText: Self.answer)
        let response = try await recall.run(RecallRequest(context: context, trigger: .ambient))
        #expect(response.suggestions.allSatisfy { $0.confidence < SurfacePolicy.Settings().threshold })
    }

    @Test func aShortReplyKeepsItsQuestionAndBothSourceLocations() async throws {
        let fixture = try MessageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let (store, vectors, _) = try prepare(fixture)
        try await fixture.database.write { db in
            try db.execute(sql: "UPDATE message SET text = 'Which vineyard do his relatives own?' WHERE ROWID = 101")
            try db.execute(sql: "UPDATE message SET text = 'Silverbrook Cellars.' WHERE ROWID = 102")
        }
        let quote = "Which vineyard do his relatives own?\nSilverbrook Cellars."
        let recall = Recall(store: store, vectors: vectors, embedder: PassageTestEmbedder(preferred: quote), messages: MessagesReader(url: fixture.url))
        let response = try await recall.run(RecallRequest(context: .text("Which winery did the delivery person mention?"), trigger: .pull))
        let evidence = try #require(response.suggestions.first?.evidence)
        #expect(evidence.text == quote)
        #expect(evidence.sources.compactMap { $0.message?.rowID } == [101, 102])
    }

    @Test func offsetsSurviveEmojiAndDistinctSourcesStayDistinct() throws {
        let date = Date(timeIntervalSince1970: 100)
        let item = Item(id: 1, source: .notes, path: "notes:demo", kind: .note, title: "Travel", size: 1,
                        created: date, modified: date, lastUsed: nil)
        let text = "🧑🏽‍🌾 A different sentence.\n" + Self.answer
        let unit = AppearsCore.Unit(id: 2, itemID: item.id, kind: .text, locator: .whole, text: text)
        for passage in PassageSelector.passages(text, item: item, unit: unit, message: nil, modified: date) {
            let source = try #require(passage.sources.first)
            #expect((text as NSString).substring(with: NSRange(location: source.utf16Location, length: source.utf16Length)) == passage.text)
        }
        let a = PassageEvidence(text: Self.answer, sources: [.init(itemID: 1, unitID: 2, message: nil, modified: date, utf16Location: 10, utf16Length: 30)], cosine: 1)
        let b = PassageEvidence(text: Self.answer, sources: [.init(itemID: 2, unitID: 3, message: nil, modified: date, utf16Location: 10, utf16Length: 30)], cosine: 1)
        #expect(!a.overlaps(b), "Identical words in distinct sources are not duplicates")
    }

    private func candidate(_ text: String, number: Int, store: IndexStore) throws -> Suggestion {
        let date = Date(timeIntervalSince1970: 100)
        let item = Item(source: .notes, path: "notes:passage-\(number)", kind: .note, title: "Note \(number)",
                        size: Int64(text.utf8.count), created: date, modified: date, lastUsed: nil)
        let (id, _) = try store.record(item, signature: "fixture")
        _ = try store.replaceUnits(itemID: id, title: item.title, units: [
            (AppearsCore.Unit(kind: .text, locator: .whole, text: text), [Float(0.95), 0.31225, 0]),
        ])
        let stored = try #require(try store.item(path: item.path))
        let unit = try #require(try store.units(itemID: id).first?.unit)
        return Suggestion(item: stored, unit: unit, reason: "Related", snippet: text, score: 1, confidence: 0.9,
                          features: Features(cosine: 0.95, zScore: 5, agreement: true, entityHit: true,
                                             daysSinceTouched: 100, fused: 0.05, forgotten: 1, novelty: 1))
    }

    @Test(arguments: ["replaced", "hidden", "modified", "removed"])
    func storedEvidenceRevalidatesAgainstTheWritersCurrentSnapshot(_ change: String) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "stored-evidence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "index.sqlite")
        let writer = try IndexStore(url: url)
        let original = try candidate(Self.answer, number: 1, store: writer)
        let reader = try IndexStore(url: url, readOnly: true)
        let versions = [(item: original.item, unit: original.unit)]
        #expect(try reader.unchangedVisibleUnits(versions) == [original.unit.id])
        try writer.touch(path: original.item.path)
        #expect(try reader.unchangedVisibleUnits(versions) == [original.unit.id],
                "Usage dates can move without changing source evidence")

        switch change {
        case "replaced":
            _ = try writer.replaceUnits(itemID: original.item.id, title: original.item.title, units: [
                (AppearsCore.Unit(kind: .text, locator: .whole, text: "The recommendation was withdrawn."), [Float(1), 0, 0]),
            ])
        case "hidden":
            try writer.setNeverShow(itemID: original.item.id)
        case "modified":
            var modified = original.item
            modified.modified = modified.modified.addingTimeInterval(1)
            _ = try writer.record(modified, signature: "updated")
        default:
            _ = try writer.remove(itemIDs: [original.item.id])
        }
        #expect(try reader.unchangedVisibleUnits(versions).isEmpty,
                "A read-only MCP client must discard evidence changed or hidden by the indexer")
    }

    @Test func verboseCandidatesCannotStarveLaterEvidence() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "passage-budget-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try IndexStore(url: folder.appending(path: "index.sqlite"))
        let candidates = try (0..<47).map { number in
            try candidate((0..<12).map { "Note \(number) sentence \($0) describes ordinary household repairs." }.joined(separator: " "),
                          number: number, store: store)
        }
        for offset in [6, 11] {
            var sentences = (0..<12).map { "Note 47 sentence \($0) describes ordinary household repairs." }
            sentences[offset] = Self.answer
            let answer = try candidate(sentences.joined(separator: " "), number: 47, store: store)
            let pool = candidates + [answer]
            let results = try await PassageSelector().select(pool, query: [1, 0, 0], embedder: PassageTestEmbedder(),
                                                            store: store, messages: nil, excluded: [], question: nil, terms: [])
            #expect(results.count == pool.count)
            #expect(results.first?.id == answer.id)
            #expect(results.first?.evidence?.text.contains(Self.answer) == true)
        }
    }

    @Test func valueQuestionsSelectAndScoreTheAnsweringSourceRange() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "passage-line-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try IndexStore(url: folder.appending(path: "index.sqlite"))
        let quote = "We agreed that membership starts in spring."
        for (number, example) in [("How much was the invoice?", "Invoice total: $120."),
                                  ("What's the username?", "Username: robin.grove")].enumerated() {
            let result = try candidate(quote + "\nAn unrelated sentence about membership administration.\n" + example.1, number: number, store: store)
            let question = try #require(Question(.text(example.0)))
            #expect(MatchedLine.find(in: result.unit.text, for: question) != nil)
            let results = try await PassageSelector().select([result], query: [1, 0, 0], embedder: PassageTestEmbedder(preferred: quote),
                                                            store: store, messages: nil, excluded: [], question: question, terms: [])
            let selected = try #require(results.first)
            #expect(selected.evidence?.text.contains(example.1) == true)
            #expect(selected.line?.text == example.1)
            #expect(selected.evidence?.text.contains(selected.line?.text ?? "missing") == true)
            #expect(selected.confidence == 0, "A value constraint cannot bypass weak semantic support")
        }
    }

    @Test func sourceRangeBudgetBoundsBothParagraphsAndLongSentences() throws {
        let date = Date(timeIntervalSince1970: 100)
        let item = Item(id: 1, source: .notes, path: "notes:bounded", kind: .note, title: "Long note", size: 1,
                        created: date, modified: date, lastUsed: nil)
        for text in [(0..<200).map { "Paragraph \($0) contains a sentence." }.joined(separator: "\n"),
                     String(repeating: "word ", count: 10_000),
                     (0..<200).map { "🧑🏽‍🌾 Paragraph \($0) contains a sentence." }.joined(separator: " ")] {
            let unit = AppearsCore.Unit(id: 1, itemID: 1, kind: .text, locator: .whole, text: text)
            let passages = PassageSelector.passages(text, item: item, unit: unit, message: nil, modified: date)
            #expect(!passages.isEmpty)
            #expect(passages.count <= 47, "At most 24 source ranges plus their adjacent pairs")
            #expect(passages.allSatisfy { $0.text.count <= 480 })
            for passage in passages {
                let source = try #require(passage.sources.first)
                #expect((text as NSString).substring(with: NSRange(location: source.utf16Location, length: source.utf16Length)) == passage.text)
            }
            #expect(passages.contains { passage in
                passage.sources.contains { $0.utf16Location + $0.utf16Length > (text as NSString).length - 480 }
            }, "The range cap must retain the source's tail, including long single sentences")
        }
    }

    @Test func staleVisibleQuestionCannotConstrainTheActiveDraft() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "passage-context-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try IndexStore(url: folder.appending(path: "index.sqlite"))
        let design = "The kitchen design uses white oak cabinets and a blue island."
        let result = try candidate(design + "\nAn older planning discussion.\nDeadline: August 14, 2023.", number: 0, store: store)
        let vectors = VectorIndex(dimension: 3)
        vectors.upsert(id: result.unit.id, kind: .text, vector: [0.95, 0.31225, 0])
        let context = ContextSnapshot(appName: "Mail", focusedText: "Can you review the new kitchen design?",
                                      visibleText: "When is the deadline?")
        #expect(Question(context)?.kinds.contains(.date) == true)
        let recall = Recall(store: store, vectors: vectors, embedder: PassageTestEmbedder(preferred: design))
        let response = try await recall.run(RecallRequest(context: context, trigger: .pull))
        let selected = try #require(response.suggestions.first)
        #expect(selected.evidence?.text == design)
        #expect(selected.line == nil)
    }

    private func photo(_ fixture: MessageFixture, store: IndexStore, kind: UnitKind = .text,
                       locator: Locator = .whole, text: String = "Silverbrook Cellars tasting invitation", rowID: Int64 = 3) throws -> Suggestion {
        let reader = MessagesReader(url: fixture.url)
        let message = try #require(try reader.database.message(rowID: rowID))
        let entry = try #require(reader.entries(for: message, chat: nil, settings: SourceSettings()).first { $0.item.kind == .image })
        let (id, _) = try store.record(entry.item, signature: entry.signature)
        _ = try store.replaceUnits(itemID: id, title: entry.item.title, units: [
            (AppearsCore.Unit(kind: kind, locator: locator, text: text), [Float(0.95), 0.31225, 0]),
        ])
        return Suggestion(item: try #require(try store.item(path: entry.item.path)),
                          unit: try #require(try store.units(itemID: id).first?.unit),
                          reason: "Related", snippet: text, score: 1, confidence: 0.9,
                          features: Features(cosine: 0.95, zScore: 5, agreement: true, entityHit: true,
                                             daysSinceTouched: 100, fused: 0.05, forgotten: 1, novelty: 1))
    }

    @Test func photoOnlyMessageRetainsItsOwnOCRAndAttachment() async throws {
        let fixture = try MessageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let store = try IndexStore(url: fixture.folder.appending(path: "evidence/index.sqlite"))
        let original = try photo(fixture, store: store)
        let results = try await PassageSelector().select([original], query: [1, 0, 0], embedder: PassageTestEmbedder(),
                                                        store: store, messages: MessagesReader(url: fixture.url), excluded: [], question: nil, terms: [])
        #expect(results == [original])
        #expect(results.first?.item.message?.attachmentPath == fixture.photo.path)
        #expect(results.first?.item.message?.rowID == 3)
    }

    @Test(arguments: [UnitKind.text, .image])
    func conversationScopeRaisesPhotoRankWithoutRaisingConfidence(_ kind: UnitKind) async throws {
        let fixture = try MessageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let store = try IndexStore(url: fixture.folder.appending(path: "evidence/index.sqlite"))
        let original = try photo(fixture, store: store, kind: kind)
        let lexical = try LexicalTerms("Silverbrook tasting invitation", store: store)
        let selector = PassageSelector()
        let global = try await selector.select([original], query: [1, 0, 0], embedder: PassageTestEmbedder(),
                                                store: store, messages: MessagesReader(url: fixture.url), excluded: [],
                                                question: nil, terms: [], lexical: lexical)
        let scoped = try await selector.select([original], query: [1, 0, 0], embedder: PassageTestEmbedder(),
                                                store: store, messages: MessagesReader(url: fixture.url), excluded: [],
                                                question: nil, terms: [], lexical: lexical,
                                                scopedChats: [try #require(original.item.message?.chatID)])
        let unscopedResult = try #require(global.first)
        let scopedResult = try #require(scoped.first)
        #expect(scopedResult.score > unscopedResult.score)
        #expect(scopedResult.confidence == unscopedResult.confidence)
        #expect(scopedResult.item.message == unscopedResult.item.message)
    }

    @Test(arguments: [UnitKind.text, .image])
    func unsentPhotoParentIsDiscardedAfterInference(_ kind: UnitKind) async throws {
        let fixture = try MessageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let store = try IndexStore(url: fixture.folder.appending(path: "evidence/index.sqlite"))
        let original = try photo(fixture, store: store, kind: kind)
        let note = try candidate(Self.answer, number: 0, store: store)
        let embedder = PassageTestEmbedder(onEmbed: { [database = fixture.database] in
            try database.write { db in try db.execute(sql: "UPDATE message SET date_retracted = 1 WHERE ROWID = 3") }
        })
        let results = try await PassageSelector().select([original, note], query: [1, 0, 0], embedder: embedder,
                                                        store: store, messages: MessagesReader(url: fixture.url), excluded: [], question: nil, terms: [])
        #expect(results.map(\.id) == [note.id])
    }

    @Test func inheritedPhotoContextStillResolvesToTheActualTextMessage() async throws {
        let fixture = try MessageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let (store, _, _) = try prepare(fixture)
        try await fixture.database.write { db in
            try db.execute(sql: "UPDATE message_attachment_join SET message_id = 100 WHERE attachment_id = 1")
            try db.execute(sql: "UPDATE message SET cache_has_attachments = 1 WHERE ROWID = 100")
        }
        let original = try photo(fixture, store: store, locator: .chunk(0), text: "Was this at your gate? " + Self.answer, rowID: 100)
        let results = try await PassageSelector().select([original], query: [1, 0, 0], embedder: PassageTestEmbedder(),
                                                        store: store, messages: MessagesReader(url: fixture.url), excluded: [], question: nil, terms: [])
        #expect(results.first?.item.kind == .message)
        #expect(results.first?.item.message?.rowID == 102)
        #expect(results.first?.evidence?.text == Self.answer)
    }

    @Test(arguments: ["unsend", "attachment", "hidden"])
    func promotedPhotoContextRetainsDiscoveryValidation(_ change: String) async throws {
        let fixture = try MessageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let (store, _, _) = try prepare(fixture)
        try await fixture.database.write { db in
            try db.execute(sql: "UPDATE message_attachment_join SET message_id = 100 WHERE attachment_id = 1")
            try db.execute(sql: "UPDATE message SET cache_has_attachments = 1 WHERE ROWID = 100")
        }
        let original = try photo(fixture, store: store, locator: .chunk(0), text: "Was this at your gate? " + Self.answer, rowID: 100)
        let embedder = PassageTestEmbedder(onEmbed: { [database = fixture.database] in
            if change == "hidden" { try store.setNeverShow(itemID: original.id) }
            else {
                try database.write { db in
                    if change == "unsend" { try db.execute(sql: "UPDATE message SET date_retracted = 1 WHERE ROWID = 100") }
                    else { try db.execute(sql: "DELETE FROM message_attachment_join WHERE message_id = 100") }
                }
            }
        })
        let results = try await PassageSelector().select([original], query: [1, 0, 0], embedder: embedder,
                                                        store: store, messages: MessagesReader(url: fixture.url), excluded: [], question: nil, terms: [])
        #expect(results.isEmpty)
    }

    @Test(arguments: [true, false])
    func identicalQuotesFromDifferentMessagesRemainDistinct(_ live: Bool) async throws {
        let fixture = try MessageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let store = try IndexStore(url: fixture.folder.appending(path: "evidence/index.sqlite"))
        let vectors = VectorIndex(dimension: 3)
        let reader = MessagesReader(url: fixture.url)
        for (number, rowID) in [Int64(100), 200].enumerated() {
            try fixture.add(rowID, text: Self.answer, date: fixture.old.addingTimeInterval(Double(number + 1) * 86_400))
            let message = try #require(try reader.database.message(rowID: rowID))
            let entry = try #require(reader.entries(for: message, chat: nil, settings: SourceSettings()).first)
            let (id, _) = try store.record(entry.item, signature: entry.signature)
            let text = live ? Self.answer : "An earlier discussion \(number).\n" + Self.answer
            let added = try store.replaceUnits(itemID: id, title: entry.item.title, units: [
                (AppearsCore.Unit(kind: .text, locator: .whole, text: text), [Float(0.95), 0.31225, 0]),
            ])
            for unit in added.added { vectors.upsert(id: unit.id, kind: unit.kind, vector: [0.95, 0.31225, 0]) }
        }
        let recall = Recall(store: store, vectors: vectors, embedder: PassageTestEmbedder(), messages: live ? reader : nil)
        let response = try await recall.run(RecallRequest(context: .text("Which winery did the delivery person recommend?"), trigger: .pull))
        #expect(Set(response.suggestions.compactMap { $0.item.message?.rowID }) == [100, 200])
        #expect(response.suggestions.allSatisfy { $0.evidence?.text == Self.answer })
    }
}
