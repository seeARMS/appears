import CoreGraphics
import Foundation
import Testing
@testable import AppearsCore

/// Known vectors let these tests prove the UI's search path uses embeddings even when
/// the question and the stored text have no words in common.
private struct SearchTestEmbedder: Embedder {
    let modelID = "search-test"
    let dimension = 3
    let supportsImages = true
    func embed(queries: [String]) async throws -> [[Float]] { queries.map { _ in [1, 0, 0] } }
    func embed(documents: [EmbeddingDocument]) async throws -> [[Float]] { documents.map { _ in [1, 0, 0] } }
    func embed(images: [CGImage]) async throws -> [[Float]] { images.map { _ in [1, 0, 0] } }
}

@Suite struct SearchTests {
    private func engine() throws -> (Engine, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "appears-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (try Engine(folder: folder, embedder: SearchTestEmbedder(), settings: SourceSettings()), folder)
    }

    @discardableResult
    private func add(_ engine: Engine, path: String, source: ItemSource = .file, kind: ItemKind = .document,
                     vector: [Float] = [1, 0, 0], age: Double = 0, chatID: Int64? = nil,
                     title: String? = nil, text: String = "Ruiz cabinetry estimate") throws -> Int64 {
        let date = Date().addingTimeInterval(-age * 86_400)
        let rowID = Int64(try engine.store.counts().units + 1)
        let reference = chatID.map { MessageReference(rowID: rowID, guid: path, chatID: $0, conversationURL: nil) }
        let item = Item(source: source, path: path, kind: kind, title: title ?? (path as NSString).lastPathComponent,
                        size: 1, created: date, modified: date, lastUsed: nil, message: reference)
        let (id, _) = try engine.store.record(item, signature: "test")
        let units = try engine.store.replaceUnits(itemID: id, title: item.title, units: [
            (AppearsCore.Unit(kind: kind == .image ? .image : .text, locator: .whole, text: text), vector),
        ]).added
        for unit in units { engine.vectors.upsert(id: unit.id, kind: unit.kind, vector: vector) }
        return id
    }

    @Test func semanticSearchIncludesRecentItemsAndImagesWithoutLexicalOverlap() async throws {
        let (engine, folder) = try engine()
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = try add(engine, path: folder.appending(path: "estimate.md").path)
        let image = try add(engine, path: folder.appending(path: "photo.jpg").path, kind: .image, age: 500)
        _ = try add(engine, path: folder.appending(path: "unrelated.md").path, vector: [0, 1, 0], age: 500)
        let payload = try JSONEncoder().encode(SearchRequest(text: "renovation budget", limit: 2))
        let response = try JSONDecoder().decode(RecallResponse.self, from: await engine.handle(.search, payload: payload))
        #expect(Set(response.suggestions.map(\.id)) == [document, image])
        #expect(response.suggestions.allSatisfy { $0.features.forgotten == 1 })
        #expect(response.suggestions.allSatisfy { !$0.features.entityHit })
        #expect(response.suggestions.contains { $0.features.daysSinceTouched < 1 })
        let stats = try engine.journal.stats(days: 7)
        #expect(stats.pulls == 0 && stats.ambient == 0 && stats.shadow == 0)
    }

    @Test func shortQueriesWorkAndAllExclusionsApply() async throws {
        let (engine, folder) = try engine()
        defer { try? FileManager.default.removeItem(at: folder) }
        let allowed = try add(engine, path: folder.appending(path: "allowed.md").path)
        _ = try add(engine, path: folder.appending(path: "excluded/private.md").path)
        _ = try add(engine, path: "notes:demo", source: .notes, kind: .note)
        _ = try add(engine, path: "messages:demo", source: .messages, kind: .message)
        _ = try add(engine, path: folder.appending(path: "excluded-kind.pdf").path, kind: .pdf)
        let blocked = try add(engine, path: folder.appending(path: "blocked.md").path)
        try engine.store.setNeverShow(itemID: blocked)
        let sources = SourceSettings(excludes: [folder.appending(path: "excluded").path], excludedKinds: [.pdf], notes: false, messages: false)
        let response = try await Search(recall: engine.recall).run(SearchRequest(text: "wifi"), sources: sources)
        #expect(response.query.denseCharacters == 4)
        #expect(response.suggestions.map(\.id) == [allowed])
    }

    @Test func emptyQueriesReturnNothingAndLimitsAreBounded() async throws {
        let (engine, folder) = try engine()
        defer { try? FileManager.default.removeItem(at: folder) }
        for index in 0..<25 { try add(engine, path: folder.appending(path: "\(index).md").path) }
        let search = Search(recall: engine.recall)
        #expect(try await search.run(SearchRequest(text: " \n "), sources: SourceSettings()).suggestions.isEmpty)
        #expect(try await search.run(SearchRequest(text: "wifi", limit: 100), sources: SourceSettings()).suggestions.count == 20)
        #expect(try await search.run(SearchRequest(text: "wifi", limit: -1), sources: SourceSettings()).suggestions.count == 1)
    }

    @Test func strongestMessageRepresentsConversationBeforeCandidateAndResultLimits() async throws {
        let (engine, folder) = try engine()
        defer { try? FileManager.default.removeItem(at: folder) }
        // More duplicates than Recall's 24-item pool: grouping only the final response
        // would leave a single row and lose the other conversations below them.
        for index in 0..<30 {
            try add(engine, path: "messages:duplicate-\(index)", source: .messages, kind: .message,
                    vector: [0.99, 0.1, 0], chatID: 1)
        }
        let best = try add(engine, path: "messages:best", source: .messages, kind: .message, chatID: 1)
        var expected: Set<Int64> = [best]
        for chat in 2...20 {
            expected.insert(try add(engine, path: "messages:chat-\(chat)", source: .messages, kind: .message,
                                    vector: [0.9, 0.4, 0], chatID: Int64(chat)))
        }
        let payload = try JSONEncoder().encode(SearchRequest(text: "renovation budget"))
        let response = try JSONDecoder().decode(RecallResponse.self, from: await engine.handle(.search, payload: payload))
        #expect(response.suggestions.first?.id == best)
        #expect(Set(response.suggestions.map(\.id)) == expected)
        #expect(response.suggestions.count == 20)
        #expect(Set(response.suggestions.compactMap { $0.item.message?.chatID }).count == 20)
        let stats = try engine.journal.stats(days: 7)
        #expect(stats.pulls == 0 && stats.ambient == 0 && stats.shadow == 0)
        let related = try await engine.recall.run(RecallRequest(context: .text("renovation budget"), trigger: .pull))
        #expect(related.suggestions.count == 3)
        #expect(related.suggestions.allSatisfy { $0.item.message?.chatID == 1 })
    }

    @Test func groupingPreservesPhotosDistinctChatsAndItemsWithoutConversationMetadata() async throws {
        let (engine, folder) = try engine()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try add(engine, path: "messages:one", source: .messages, kind: .message, chatID: 1, title: "Kitchen")
        let second = try add(engine, path: "messages:two", source: .messages, kind: .message, chatID: 2, title: "Kitchen")
        let photo = try add(engine, path: "messages:one:photo:a", source: .messages, kind: .image, chatID: 1)
        let otherPhoto = try add(engine, path: "messages:one:photo:b", source: .messages, kind: .image, chatID: 1)
        let unknown = try add(engine, path: "messages:unknown", source: .messages, kind: .message, title: "Kitchen")
        let otherUnknown = try add(engine, path: "messages:other-unknown", source: .messages, kind: .message, title: "Kitchen")
        let document = try add(engine, path: folder.appending(path: "Kitchen").path)
        let note = try add(engine, path: "notes:Kitchen", source: .notes, kind: .note, title: "Kitchen")
        let response = try await Search(recall: engine.recall).run(SearchRequest(text: "renovation budget"), sources: SourceSettings())
        #expect(Set(response.suggestions.map(\.id)) == [first, second, photo, otherPhoto, unknown, otherUnknown, document, note])
    }

    @Test func hiddenMessageDoesNotSuppressOtherMatchesInItsConversation() async throws {
        let (engine, folder) = try engine()
        defer { try? FileManager.default.removeItem(at: folder) }
        let hidden = try add(engine, path: "messages:hidden", source: .messages, kind: .message, chatID: 1)
        let allowed = try add(engine, path: "messages:allowed", source: .messages, kind: .message,
                              vector: [0.9, 0.4, 0], chatID: 1)
        try engine.store.setNeverShow(itemID: hidden)
        let search = Search(recall: engine.recall)
        let response = try await search.run(SearchRequest(text: "renovation budget"), sources: SourceSettings())
        #expect(response.suggestions.map(\.id) == [allowed])
        #expect(try await search.run(SearchRequest(text: "renovation budget"), sources: SourceSettings(messages: false)).suggestions.isEmpty)
    }

    @Test func explicitKeywordsKeepVerbsQualifiersAndShortNumbers() throws {
        let (engine, folder) = try engine()
        defer { try? FileManager.default.removeItem(at: folder) }
        for (text, expected) in [
            ("book delivery", ["book", "delivery"]),
            ("revised proposal", ["revised", "proposal"]),
            ("did Maya return the $82 deposit?", ["maya", "return", "82", "deposit"]),
            ("not delivered", ["not", "delivered"]),
        ] {
            let query = try SearchQuery(text, store: engine.store)
            #expect(query.terms == expected)
        }
    }

    @Test func separateDiscussionsWithTheSamePersonRemainSearchable() async throws {
        let (engine, folder) = try engine()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = try add(engine, path: "messages:old", source: .messages, kind: .message, age: 900, chatID: 1,
                          text: "Me: The original delivery is booked for September.")
        let recent = try add(engine, path: "messages:recent", source: .messages, kind: .message, chatID: 1,
                             text: "Sender: The revised delivery arrives Friday.")
        let result = try await Search(recall: engine.recall).run(SearchRequest(text: "delivery", limit: 2), sources: SourceSettings())
        #expect(Set(result.suggestions.map(\.id)) == [old, recent])
    }

    @Test func overlappingWindowsMergeButAnotherDiscussionSurvives() async throws {
        let (engine, folder) = try engine()
        defer { try? FileManager.default.removeItem(at: folder) }
        try add(engine, path: "messages:first", source: .messages, kind: .message, chatID: 1,
                text: "Me: Please book the delivery.\nSender: The blue cabinet is ready.\nMe: Friday is convenient for us.")
        try add(engine, path: "messages:overlap", source: .messages, kind: .message, chatID: 1,
                text: "Sender: The blue cabinet is ready.\nMe: Friday is convenient for us.\nSender: I will confirm the delivery.")
        let separate = try add(engine, path: "messages:separate", source: .messages, kind: .message, age: 30, chatID: 1,
                               text: "Sender: The garden delivery arrives on Monday.")
        let result = try await Search(recall: engine.recall).run(SearchRequest(text: "delivery"), sources: SourceSettings())
        #expect(result.suggestions.count == 2)
        #expect(result.suggestions.contains { $0.id == separate })
    }

    @Test func widerRetrievalFindsDistinctPassagesBelowRepeatedWindows() async throws {
        let (engine, folder) = try engine()
        defer { try? FileManager.default.removeItem(at: folder) }
        for index in 0..<420 {
            try add(engine, path: "messages:repeated-\(index)", source: .messages, kind: .message,
                    vector: [0.99, 0.1, 0], chatID: 1, text: "Sender: The estimate is attached for your review.")
        }
        let target = try add(engine, path: "messages:distinct", source: .messages, kind: .message,
                             vector: [0.9, 0.4, 0], chatID: 2, text: "Sender: Here are the measurements we discussed.")
        let result = try await Search(recall: engine.recall).run(SearchRequest(text: "renovation budget", limit: 2), sources: SourceSettings())
        #expect(result.suggestions.count == 2)
        #expect(result.suggestions.contains { $0.id == target })
    }

    @Test func indexedContextConnectsSharedIdentifiersAcrossLongGapsWithoutHiddenItems() async throws {
        let (engine, folder) = try engine()
        defer { try? FileManager.default.removeItem(at: folder) }
        let anchor = try add(engine, path: "messages:ack", source: .messages, kind: .message, chatID: 1,
                             text: "Sender: I will take care of reference 482.")
        try add(engine, path: "messages:subject", source: .messages, kind: .message, age: 0.1, chatID: 1,
                text: "Me: Reference 482 is the revised cabinet delivery.")
        let hidden = try add(engine, path: "messages:private", source: .messages, kind: .message, chatID: 1,
                             text: "Sender: Reference 482 secret detail.")
        try engine.store.setNeverShow(itemID: hidden)
        let result = try await Search(recall: engine.recall).run(SearchRequest(text: "reference 482", limit: 1), sources: SourceSettings())
        let passage = try #require(result.suggestions.first)
        #expect(passage.unit.text.contains("revised cabinet delivery"))
        #expect(!passage.unit.text.contains("secret detail"))
        #expect(passage.id == anchor || passage.unit.text.contains("take care"))
    }

    @Test func recentFollowupsComplementLexicalRankingWithinRelevantChats() throws {
        let (engine, folder) = try engine()
        defer { try? FileManager.default.removeItem(at: folder) }
        for index in 0..<12 {
            try add(engine, path: "messages:history-\(index)", source: .messages, kind: .message, age: 800,
                    chatID: 1, text: "delivery delivery delivery")
        }
        let recent = try add(engine, path: "messages:followup", source: .messages, kind: .message,
                             chatID: 1, text: "The revised cabinet delivery is reference 482 for the workshop.")
        let hits = try engine.store.recentMessageHits("delivery", chatIDs: [1])
        let units = try engine.store.units(ids: hits.map(\.unitID))
        #expect(units.values.contains { $0.itemID == recent })
        #expect(hits.count == 8)
        try engine.store.setNeverShow(itemID: recent)
        let hiddenHits = try engine.store.recentMessageHits("delivery", chatIDs: [1])
        let hiddenUnits = try engine.store.units(ids: hiddenHits.map(\.unitID))
        #expect(!hiddenUnits.values.contains { $0.itemID == recent })
        #expect(try engine.store.recentMessageHits("delivery", chatIDs: [2]).isEmpty)
    }

    @Test func strongOldEvidenceStillBeatsAVagueRecentMatchAndLimitDoesNotChangeTheWinner() async throws {
        let (engine, folder) = try engine()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = try add(engine, path: "messages:confirmation", source: .messages, kind: .message,
                          vector: [1, 0, 0], age: 900, chatID: 1, text: "Sender: The studio reservation confirmation is reference 739.")
        try add(engine, path: "messages:vague", source: .messages, kind: .message,
                vector: [0.7, 0.7, 0], chatID: 2, text: "Sender: Shall we meet sometime?")
        let search = Search(recall: engine.recall)
        for limit in [1, 20] {
            let result = try await search.run(SearchRequest(text: "studio reservation confirmation", limit: limit), sources: SourceSettings())
            #expect(result.suggestions.first?.id == old)
        }
    }
}
