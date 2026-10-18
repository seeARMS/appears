import AppearsMessages
import Foundation
import GRDB
import Testing
@testable import AppearsCore

@Suite struct RetrievalPlanTests {
    @Test func primaryQueryKeepsVerbsQualifiersNegationAndShortNumbers() {
        let query = QueryBuilder.build(ContextSnapshot(focusedText: "Was the final rent paid or not waived? It was 85, not 805.")) { terms in
            (Dictionary(uniqueKeysWithValues: terms.map { ($0, 500) }), 600)
        }
        for term in ["final", "rent", "paid", "not", "waived", "85", "805"] {
            #expect(query.rareTerms.contains(term), "Do not erase a supplied word because of its grammar, length, or frequency")
        }
    }

    @Test func unrelatedHistoryCannotRewriteThePrimaryQuestion() {
        let context = ContextSnapshot(appName: "Messages", windowTitle: "Morgan Hale",
                                      focusedText: "How much was the final apartment bill?",
                                      visibleText: "Bring work lights and batteries. Want to walk?")
        let plan = RetrievalPlan(context)
        #expect(plan.primary.selection == context.focusedText)
        #expect(plan.primary.visibleText.isEmpty)
        #expect(plan.primary.windowTitle.isEmpty)
        #expect(plan.surrounding?.visibleText == context.visibleText)
    }

    @Test func selectionTakesPrecedenceOverDraft() {
        let plan = RetrievalPlan(ContextSnapshot(selection: "What was the confirmation code?", focusedText: "How much is the apartment bill?"))
        #expect(plan.primary.selection == "What was the confirmation code?")
    }

    @Test func explicitShortQueriesStayVerbatim() {
        let plan = RetrievalPlan(ContextSnapshot(selection: "Joan", origin: .text))
        let query = QueryBuilder.build(plan.primary) { _ in (["joan": 20], 100) }
        #expect(plan.hasActiveText)
        #expect(query.dense == "Joan")
        #expect(query.fullText == "\"joan\"")
    }

    @Test(arguments: [ContextSnapshot.Origin.accessibility, .ocr])
    func shortSelectionOverridesLongDraft(_ origin: ContextSnapshot.Origin) {
        let plan = RetrievalPlan(ContextSnapshot(selection: "Joan", focusedText: "How much was the final apartment bill?", origin: origin))
        let query = QueryBuilder.build(plan.primary) { _ in (["joan": 20], 100) }
        #expect(plan.hasActiveText)
        #expect(query.dense == "Joan")
        #expect(query.fullText == "\"joan\"")
    }

    @Test func repeatedAmountsNeedIndependentTopicSupport() {
        let bill = Unit(id: 1, kind: .text, locator: .whole, text: "The apartment statement asks for $845.")
        let confirmation = Unit(id: 2, kind: .text, locator: .whole, text: "We only owe $845 after the leasing office corrected it.")
        let furniture = Unit(id: 3, kind: .text, locator: .whole, text: "The new bed costs $845.")
        let vectors: [Int64: [Float]] = [1: [1, 0], 2: [0.9, 0.43589], 3: [0.65, 0.75993]]
        #expect(DiscussionLink.connects(bill, confirmation, vectors: vectors))
        #expect(!DiscussionLink.connects(bill, furniture, vectors: vectors))
        #expect(DiscussionLink.references("We met in 2026").isEmpty)
        #expect(DiscussionLink.references("The charges were $85, $2,026 and $8.45; order AB-123.") == ["85", "2026", "8.45", "ab-123"])
    }

    @Test func scopeIsAppliedBeforeCandidateLimitAndDoesNotIncludeHiddenMessages() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try IndexStore(url: folder.appending(path: "index.sqlite"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var scopedID: Int64 = 0
        for number in 0..<12 {
            let reference = MessageReference(rowID: Int64(number), guid: "fixture-\(number)", chatID: number == 11 ? 2 : 1, conversationURL: nil)
            let text = number == 11 ? "The final charge was $845." : "Final charge final charge final charge."
            let item = Item(source: .messages, path: "messages:\(number)", kind: .message, title: "Same display name",
                            size: 1, created: date.addingTimeInterval(Double(number)), modified: date, lastUsed: nil, message: reference)
            let (id, _) = try store.record(item, signature: "fixture")
            _ = try store.replaceUnits(itemID: id, title: item.title, units: [(Unit(kind: .text, locator: .whole, text: text), [Float(1), 0, 0])])
            if number == 11 { scopedID = id }
        }
        let scoped = try store.messageHits("charge", chatIDs: [2], limit: 1)
        #expect(scoped.count == 1)
        #expect(try store.units(ids: scoped.map(\.unitID)).values.first?.itemID == scopedID)
        let recent = try store.messageHits("charge", chatIDs: [1], limit: 1, newestFirst: true)
        let latestID = try #require(try store.item(path: "messages:10")?.id)
        #expect(try store.units(ids: recent.map(\.unitID)).values.first?.itemID == latestID)
        try store.setNeverShow(itemID: scopedID)
        #expect(try store.messageHits("charge", chatIDs: [2], limit: 1).isEmpty)
    }

    @Test(arguments: ["unchanged", "hidden", "unsent"], ["845", "8.45", "2026"])
    func splitDiscussionKeepsExactSourcesAndRevalidatesBoth(_ change: String, _ amount: String) async throws {
        let fixture = try MessageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let subject = "Cedar Point asks us to pay $\(amount)."
        let answer = "We only owe $\(amount). The extra rent was waived."
        let quote = subject + "\n" + answer
        try fixture.add(500, text: subject, date: fixture.old.addingTimeInterval(86_400))
        try fixture.add(501, text: answer, date: fixture.old.addingTimeInterval(86_400 + 5_400))
        let store = try IndexStore(url: fixture.folder.appending(path: "index.sqlite"))
        let reader = MessagesReader(url: fixture.url)
        let vectors = VectorIndex(dimension: 3)
        var supportID: Int64 = 0
        for rowID: Int64 in [500, 501] {
            let message = try #require(try reader.database.message(rowID: rowID))
            let entry = try #require(reader.entries(for: message, chat: nil, settings: SourceSettings()).first)
            let (id, _) = try store.record(entry.item, signature: entry.signature)
            let vector: [Float] = [0.95, 0.31225, 0]
            let update = try store.replaceUnits(itemID: id, title: entry.item.title, units: [
                (Unit(kind: .text, locator: .whole, text: message.text!), vector),
            ])
            for unit in update.added { vectors.upsert(id: unit.id, kind: .text, vector: vector) }
            if rowID == 500 { supportID = id }
        }
        let sourceID = supportID
        let embedder = PassageTestEmbedder(preferred: quote, onEmbed: {
            if change == "hidden" { try store.setNeverShow(itemID: sourceID) }
            if change == "unsent" {
                try fixture.database.write { db in try db.execute(sql: "UPDATE message SET date_retracted = 1 WHERE ROWID = 500") }
            }
        })
        let recall = Recall(store: store, vectors: vectors, embedder: embedder, messages: reader)
        var context = ContextSnapshot(focusedText: "How much was the Cedar Point bill?")
        context.messageChatIDs = [1]
        let response = try await recall.run(RecallRequest(context: context, trigger: .pull))
        if change == "unchanged" {
            let result = try #require(response.suggestions.first)
            #expect(result.evidence?.text == quote)
            #expect(result.evidence?.sources.compactMap { $0.message?.rowID } == [500, 501])
            #expect(result.item.message?.rowID == 501)
        } else {
            #expect(response.suggestions.isEmpty)
        }
    }

    @Test func sharedQuestionCannotHideDifferentFollowUps() {
        func source(_ id: Int64) -> PassageEvidence.Source {
            .init(itemID: id, unitID: id, message: nil, modified: .distantPast, utf16Location: 0, utf16Length: 10)
        }
        let initial = PassageEvidence(text: "", sources: [source(1)], cosine: 1)
        let confirmed = PassageEvidence(text: "", sources: [source(1), source(2)], cosine: 1)
        let corrected = PassageEvidence(text: "", sources: [source(1), source(3)], cosine: 1)
        #expect(!initial.overlaps(confirmed))
        #expect(!confirmed.overlaps(corrected))
        #expect(confirmed.overlaps(confirmed))
    }
}
