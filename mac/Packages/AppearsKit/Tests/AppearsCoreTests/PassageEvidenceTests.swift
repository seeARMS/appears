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
    var preferred = PassageEvidenceTests.answer
    var onEmbed: (@Sendable () throws -> Void)?
    func embed(queries: [String]) async throws -> [[Float]] {
        queries.map { $0.contains("amplifier") ? [0, 0, 1] : [1, 0, 0] }
    }
    func embed(documents: [EmbeddingDocument]) async throws -> [[Float]] {
        try onEmbed?()
        return documents.map { document in
            if document.text == preferred { return [1, 0, 0] }
            return document.text.contains(preferred) ? [0.95, 0.31225, 0] : [0, 1, 0]
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

    @Test func verboseCandidatesCannotStarveLaterEvidence() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "passage-budget-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try IndexStore(url: folder.appending(path: "index.sqlite"))
        var candidates = try (0..<47).map { number in
            try candidate((0..<12).map { "Note \(number) sentence \($0) describes ordinary household repairs." }.joined(separator: " "),
                          number: number, store: store)
        }
        let lateText = (0..<11).map { "Note 47 sentence \($0) describes ordinary household repairs." }.joined(separator: " ") + " " + Self.answer
        let answer = try candidate(lateText, number: 47, store: store)
        candidates.append(answer)
        let results = try await PassageSelector().select(candidates, query: [1, 0, 0], embedder: PassageTestEmbedder(),
                                                        store: store, messages: nil, excluded: [], question: nil, terms: [])
        #expect(results.count == candidates.count)
        #expect(results.first?.id == answer.id)
        #expect(results.first?.evidence?.text == Self.answer)
    }

    @Test func valueQuestionsSelectAndScoreTheAnsweringSourceRange() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "passage-line-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try IndexStore(url: folder.appending(path: "index.sqlite"))
        let quote = "We agreed that membership starts in spring."
        let result = try candidate(quote + "\nAn unrelated sentence about membership administration.\nInvoice total: $120.", number: 0, store: store)
        let question = try #require(Question(.text("How much was the invoice?")))
        #expect(MatchedLine.find(in: result.unit.text, for: question) != nil)
        let results = try await PassageSelector().select([result], query: [1, 0, 0], embedder: PassageTestEmbedder(preferred: quote),
                                                        store: store, messages: nil, excluded: [], question: question, terms: ["invoice"])
        let selected = try #require(results.first)
        #expect(selected.evidence?.text.contains("Invoice total: $120.") == true)
        #expect(selected.line?.text == "Invoice total: $120.")
        #expect(selected.evidence?.text.contains(selected.line?.text ?? "missing") == true)
        #expect(selected.confidence == 0, "A value constraint cannot bypass weak semantic support")
    }

    @Test func sourceRangeBudgetBoundsBothParagraphsAndLongSentences() throws {
        let date = Date(timeIntervalSince1970: 100)
        let item = Item(id: 1, source: .notes, path: "notes:bounded", kind: .note, title: "Long note", size: 1,
                        created: date, modified: date, lastUsed: nil)
        for text in [(0..<200).map { "Paragraph \($0) contains a sentence." }.joined(separator: "\n"),
                     String(repeating: "word ", count: 10_000)] {
            let unit = AppearsCore.Unit(id: 1, itemID: 1, kind: .text, locator: .whole, text: text)
            let passages = PassageSelector.passages(text, item: item, unit: unit, message: nil, modified: date)
            #expect(!passages.isEmpty)
            #expect(passages.count <= 47, "At most 24 source ranges plus their adjacent pairs")
            #expect(passages.allSatisfy { $0.text.count <= 480 })
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
}
