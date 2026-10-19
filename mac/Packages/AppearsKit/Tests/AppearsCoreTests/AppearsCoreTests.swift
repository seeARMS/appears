import Foundation
import Testing

@testable import AppearsCore

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "appears-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let day: TimeInterval = 86_400

/// An index of a few made-up files, built with the hashing embedder.
private func makeIndex(_ files: [(name: String, text: String, age: Double)], now: Date = Date()) async throws -> (Recall, IndexStore, URL) {
    let folder = try temporaryFolder()
    let store = try IndexStore(url: folder.appending(path: "index.sqlite"))
    let embedder = HashingEmbedder()
    let vectors = VectorIndex(dimension: embedder.dimension)
    let indexer = Indexer(store: store, vectors: vectors, embedder: embedder, settings: SourceSettings())
    for file in files {
        let date = now.addingTimeInterval(-file.age * day)
        let item = Item(source: .file, path: folder.appending(path: file.name).path, kind: .document, title: file.name,
                        size: Int64(file.text.count), created: date, modified: date, lastUsed: nil)
        try file.text.write(toFile: item.path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: item.path)
        let (id, _) = try store.record(item, signature: "x")
        var stored = item
        stored.id = id
        try await indexer.index(stored)
    }
    return (Recall(store: store, vectors: vectors, embedder: embedder), store, folder)
}

@Suite struct ExtractorTests {
    @Test func chunksAtParagraphs() {
        let paragraph = String(repeating: "word ", count: 100)
        let chunks = Extractor.chunks(Array(repeating: paragraph, count: 10).joined(separator: "\n\n"), size: 1_100)
        #expect(chunks.count == 5)
        #expect(chunks.allSatisfy { $0.count <= 1_100 })
    }

    @Test func splitsOneLongParagraph() {
        let text = String(repeating: "A sentence goes here. ", count: 300)
        let chunks = Extractor.chunks(text, size: 500)
        #expect(chunks.count > 5)
        #expect(chunks.allSatisfy { $0.count <= 500 })
    }

    @Test func stripsHTML() {
        let text = Extractor.stripHTML("<html><style>p{}</style><p>Hello &amp; welcome</p><script>x()</script></html>")
        #expect(text.trimmingCharacters(in: .whitespaces) == "Hello & welcome")
    }
}

@Suite struct NotesTests {
    @Test func decodesNoteProtobuf() throws {
        // NoteStoreProto { document (2) { note (3) { note_text (2): "Kitchen measurements" } } }
        func field(_ number: UInt8, _ payload: [UInt8]) -> [UInt8] { [number << 3 | 2, UInt8(payload.count)] + payload }
        let text = Array("Kitchen measurements".utf8)
        let proto = field(2, [0x08, 0x01] + field(3, [0x08, 0x00] + field(2, text)))
        #expect(NotesReader.noteText(Data(proto)) == "Kitchen measurements")
    }

    @Test func gunzips() throws {
        // `printf 'hello' | gzip | xxd -i`
        let gz: [UInt8] = [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07,
                           0x00, 0x86, 0xa6, 0x10, 0x36, 0x05, 0x00, 0x00, 0x00]
        let out = try #require(NotesReader.gunzip(Data(gz)))
        #expect(String(decoding: out, as: UTF8.self) == "hello")
    }
}

@Suite struct QueryTests {
    @Test func dropsQuotedReplies() {
        let text = "Sounds good, Thursday works.\n\nOn Mon, Oct 13, 2026 at 9:14 AM Dana Ruiz wrote:\n> Can we meet?"
        #expect(QueryBuilder.clean(text) == "Sounds good, Thursday works.")
    }

    @Test func findsNamesAndNumbers() {
        let query = QueryBuilder.build(.text("Hi Dana Ruiz, about invoice INV-20431 for the kitchen at Ruiz & Daughters Builders. Call me at (415) 555-0142."))
        #expect((query.entities + query.contextEntities).contains { $0.contains("Dana Ruiz") })
        #expect(query.identifiers.contains("INV-20431"))
        #expect(query.fullText.contains("\"INV-20431\""))
    }

    @Test func spotsRecallIntent() {
        for asking in ["Thanks! What was the wifi password again?", "do you still have the quote?", "Can you resend the permit",
                       "I’ll send you the itinerary tonight", "where's that receipt for the desk?", "I can't find the lease"] {
            #expect(QueryBuilder.recallIntent(in: asking), "\(asking)")
        }
        for not in ["lol what was I thinking", "I can find time Tuesday", "Where is the nearest pharmacy?",
                    "Let me know if Thursday works", "Send the deck to the team"] {
            #expect(!QueryBuilder.recallIntent(in: not), "\(not)")
        }
    }

    @Test func recallIntentComesFromWhatYouWrite() {
        // Someone else asking, in the window's history, isn't you asking your memory.
        let theirs = ContextSnapshot(appName: "Messages", focusedText: "ok sounds good", visibleText: "Sam: can you resend the permit?")
        #expect(!QueryBuilder.build(theirs).recallIntent)
        let yours = ContextSnapshot(appName: "Messages", focusedText: "sure, I'll send you the permit", visibleText: "Sam: is the permit still good?")
        #expect(QueryBuilder.build(yours).recallIntent)
        let selected = ContextSnapshot(appName: "Notes", selection: "where did I put the warranty card")
        #expect(QueryBuilder.build(selected).recallIntent)
    }

    @Test func fingerprintIgnoresWhitespaceButNotTopic() {
        let a = ContextSnapshot(bundleID: "com.apple.mail", windowTitle: "Re: Kitchen", focusedText: "Hello  there")
        var b = a
        b.focusedText = "Hello there"
        var c = a
        c.windowTitle = "Re: Taxes"
        #expect(a.fingerprint(salt: "s") == b.fingerprint(salt: "s"))
        #expect(a.fingerprint(salt: "s") != c.fingerprint(salt: "s"))
    }
}

@Suite struct RecallTests {
    @Test func theDecisionOrdersResultsAndIsTheirConfidence() async throws {
        var (recall, _, _) = try await makeIndex([
            ("quote.txt", "Ruiz Builders quote for kitchen cabinets and countertops, $18,400", 400),
            ("notes-today.txt", "Kitchen cabinets countertops quote, Ruiz Builders, edited today", 0.5),
            ("hiking.txt", "Zion hiking itinerary for three days, Angels Landing permit", 300),
        ])
        let context = ContextSnapshot(appName: "Mail", focusedText: "How much was the Ruiz Builders quote for the kitchen?")
        // Without a decision model, results are listed but undecided: no confidence to signal with.
        let undecided = try await recall.run(RecallRequest(context: context, trigger: .pull, limit: 3))
        #expect(!undecided.suggestions.isEmpty && undecided.suggestions.allSatisfy { !$0.decided && $0.confidence == 0 })
        #expect(undecided.unanswered == nil)

        let decider = ScriptedDecider.picking("$18,400", probability: 0.85)
        recall.decider = decider
        let response = try await recall.run(RecallRequest(context: context, trigger: .pull, limit: 3))
        let first = try #require(response.suggestions.first)
        #expect(first.item.title == "quote.txt" && first.decided && abs(first.confidence - 0.85) < 1e-9)
        // Each decided result records which model decided it, for the journal.
        #expect(response.suggestions.allSatisfy { $0.features.decider == decider.modelID })
        #expect(response.suggestions.dropFirst().allSatisfy { $0.decided && $0.confidence == 0 })
        #expect(abs((response.unanswered ?? 0) - 0.15) < 1e-9)
        // The model reads the draft as a question, the candidates and a way to say none.
        let asked = try #require(decider.requests.first)
        #expect(asked.question.contains("How much was the Ruiz Builders quote"))
        #expect(asked.options.last?.name == "none")
        #expect(asked.options.count <= DecisionPrompt.maximumOptions)

        // A failing model leaves the results undecided rather than failing the lookup.
        recall.decider = FailingDecider()
        let failed = try await recall.run(RecallRequest(context: context, trigger: .pull, limit: 3))
        #expect(!failed.suggestions.isEmpty && failed.suggestions.allSatisfy { !$0.decided })
    }

    @Test func hidingAnItemWhileTheModelDecidesDropsIt() async throws {
        var (recall, store, folder) = try await makeIndex([
            ("quote.txt", "Ruiz Builders quote for kitchen cabinets and countertops, $18,400", 400),
            ("permit.txt", "Building permit for the kitchen remodel: cabinets, countertops and outlets", 300),
        ])
        let quote = try #require(try store.item(path: folder.appending(path: "quote.txt").path))
        // "Never show this" arrives from the panel while the decision is being made.
        recall.decider = ScriptedDecider { [store] request in
            try? store.setNeverShow(itemID: quote.id)
            var result = Array(repeating: 0.0, count: request.options.count)
            let index = request.options.firstIndex { $0.description.contains("$18,400") } ?? 0
            result[index] = 0.9
            result[result.count - 1] = 0.1
            return result
        }
        let context = ContextSnapshot(appName: "Mail", focusedText: "How much was the Ruiz Builders kitchen quote?")
        let response = try await recall.run(RecallRequest(context: context, trigger: .pull, limit: 3))
        #expect(!response.suggestions.contains { $0.id == quote.id })
    }

    @Test func aMessagesPhotoIsReadByItsOwnTextNotItsConversation() async throws {
        let folder = try temporaryFolder()
        let store = try IndexStore(url: folder.appending(path: "index.sqlite"))
        let embedder = HashingEmbedder()
        let date = Date(timeIntervalSince1970: 1_000)
        let reference = MessageReference(rowID: 3, guid: "photo-guid", chatID: 9, conversationURL: nil, attachmentPath: "/demo/photo.jpg")
        let photo = Item(source: .messages, path: "messages:3:photo:photo-guid", kind: .image, title: "Photo · Rowan Ellis",
                         size: 1, created: date, modified: date, lastUsed: nil, message: reference)
        let (id, _) = try store.record(photo, signature: "test")
        let vector = try await embedder.embed(queries: ["kestrel"])[0]
        let units = try store.replaceUnits(itemID: id, title: photo.title, units: [
            (Unit(kind: .image, locator: .whole, text: ""), vector),
            (Unit(kind: .text, locator: .whole, text: "Kestrel maintenance case K-417"), vector),
            (Unit(kind: .text, locator: .chunk(0), text: "Rowan: an unsent message beside the photo"), vector),
        ]).added
        let image = try #require(units.first { $0.kind == .image })
        var stored = photo
        stored.id = id
        let recall = Recall(store: store, vectors: VectorIndex(dimension: embedder.dimension), embedder: embedder)
        let candidate = Suggestion(item: stored, unit: image, reason: "Looks related", snippet: "", score: 1, confidence: 0,
                                   features: Features(cosine: 0.9, daysSinceTouched: 1))
        let text = try #require(try recall.readable([candidate])[id])
        #expect(text.contains("K-417"))
        #expect(!text.contains("unsent"))
    }

    @Test func skipsTheOpenDocument() async throws {
        let (recall, _, folder) = try await makeIndex([
            ("a.txt", "Permit application for the kitchen remodel, city of Oakland", 100),
            ("b.txt", "Permit for kitchen remodel approved, Oakland building department", 200),
        ])
        var context = ContextSnapshot.text("Oakland kitchen remodel permit")
        context.documentPath = folder.appending(path: "a.txt").path
        let response = try await recall.run(RecallRequest(context: context, trigger: .pull))
        #expect(response.suggestions.map(\.item.title) == ["b.txt"])
    }

    @Test func explainsEntityMatches() async throws {
        let (recall, _, _) = try await makeIndex([
            ("contacts.txt", "Dana Ruiz, contractor, Ruiz & Daughters Builders", 500),
        ])
        // A name in what you're writing is strong evidence.
        let writing = ContextSnapshot(appName: "Mail", focusedText: "Email to Dana Ruiz about next week")
        let response = try await recall.run(RecallRequest(context: writing, trigger: .pull))
        let first = try #require(response.suggestions.first)
        #expect(first.reason.hasPrefix("Mentions Dana Ruiz"))
        // The same name only elsewhere in the window still explains the match, but counts for less.
        let background = try #require(try await recall.run(RecallRequest(context: .text("Email to Dana Ruiz about next week"), trigger: .pull)).suggestions.first)
        #expect(background.reason.hasPrefix("Mentions Dana Ruiz"))
    }

    @Test func journalFeaturesFromBeforeTheDecisionModelStillDecode() throws {
        let old = #"{"cosine":0.7,"zScore":3,"agreement":true,"entityHit":false,"daysSinceTouched":10,"fused":0.02,"forgotten":0.8,"novelty":1}"#
        let decoded = try JSONDecoder().decode(Features.self, from: Data(old.utf8))
        #expect(decoded.cosine == 0.7 && decoded.daysSinceTouched == 10 && !decoded.recallIntent && decoded.probability == nil)
        #expect(decoded.decider == nil)
        let current = Features(cosine: 0.5, daysSinceTouched: 2, recallIntent: true, probability: 0.9, answered: 0.95,
                               decider: "scripted")
        #expect(try JSONDecoder().decode(Features.self, from: JSONEncoder().encode(current)) == current)
    }

    @Test func recallIntentDoesNotReorder() async throws {
        let (recall, _, _) = try await makeIndex([
            ("quote.txt", "Kitchen remodel quote: cabinets, quartz countertops, six new outlets, $23,900", 400),
            ("permit.txt", "Building permit for the kitchen remodel: cabinets, countertops and outlets", 300),
            ("hiking.txt", "Zion hiking itinerary for three days, Angels Landing permit", 300),
        ])
        func run(_ text: String) async throws -> RecallResponse {
            try await recall.run(RecallRequest(context: ContextSnapshot(appName: "Messages", focusedText: text), trigger: .pull))
        }
        // The hashing embedder only sees words: the asking words are filler to it.
        let plain = try await run("the kitchen remodel quote cabinets quartz countertops outlets ok")
        let asking = try await run("the kitchen remodel quote cabinets quartz countertops outlets, can you resend it")
        #expect(asking.suggestions.count >= 2)
        #expect(asking.suggestions.allSatisfy { $0.features.recallIntent })
        #expect(!plain.suggestions.contains { $0.features.recallIntent })
        #expect(asking.suggestions.map(\.item.title) == plain.suggestions.map(\.item.title))
    }

    @Test func neverShowIsRespected() async throws {
        let (recall, store, _) = try await makeIndex([("x.txt", "Solar panel installation estimate from Sunrun", 100)])
        let first = try #require(try await recall.run(RecallRequest(context: .text("solar panel estimate"), trigger: .pull)).suggestions.first)
        try store.setNeverShow(itemID: first.item.id)
        #expect(try await recall.run(RecallRequest(context: .text("solar panel estimate"), trigger: .pull)).suggestions.isEmpty)
    }
}

@Suite struct FullTextTests {
    /// A screenshot: the image, and its OCR text as a text unit at the same locator.
    private func screenshot(_ text: String, in store: IndexStore, folder: URL, vector: [Float] = [1, 0]) throws -> [AppearsCore.Unit] {
        let date = Date().addingTimeInterval(-400 * day)
        let item = Item(source: .file, path: folder.appending(path: "shot-\(UUID().uuidString).png").path, kind: .image,
                        title: "Screenshot.png", size: 1, created: date, modified: date, lastUsed: nil)
        let (id, _) = try store.record(item, signature: "x")
        return try store.replaceUnits(itemID: id, title: item.title, units: [
            (AppearsCore.Unit(kind: .text, locator: .whole, text: text), vector), (AppearsCore.Unit(kind: .image, locator: .whole, text: text), vector),
        ]).added
    }

    @Test func countsWordsByTheIndexsOwnStemsAndOCRTextOnce() throws {
        let folder = try temporaryFolder()
        let store = try IndexStore(url: folder.appending(path: "index.sqlite"))
        _ = try screenshot("Dr. Patel at Rockridge Animal Hospital, they quoted $640 for the cleaning", in: store, folder: folder)
        let (counts, _) = try store.documentFrequencies(["quote", "itinerary", "cleaning", "hospital"])
        // "quote" and "quoted" are both "quot" to the index; the crude stem missed it.
        #expect(counts["quote"] == 1)
        #expect(counts["cleaning"] == 1)
        #expect(counts["hospital"] == 1)
        #expect(counts["itinerary"] == nil)
        #expect(try store.fullText("\"quote\"", limit: 10).count == 1)
    }

    @Test func anImageAgreesThroughItsOCRText() async throws {
        let folder = try temporaryFolder()
        let store = try IndexStore(url: folder.appending(path: "index.sqlite"))
        let embedder = HashingEmbedder()
        let vectors = VectorIndex(dimension: embedder.dimension)
        let text = "Ruiz & Daughters Builders quote Q-2291: kitchen remodel, quartz countertops, six outlets"
        let vector = try await embedder.embed(documents: [EmbeddingDocument(title: "Screenshot.png", text: text)])[0]
        // Only the image is a vector match (noisy OCR text often isn't), and only the OCR text
        // unit is in the full-text index.
        for unit in try screenshot(text, in: store, folder: folder, vector: vector) where unit.kind == .image {
            vectors.upsert(id: unit.id, kind: unit.kind, vector: vector)
        }
        let recall = Recall(store: store, vectors: vectors, embedder: embedder)
        let response = try await recall.run(RecallRequest(context: .text("the quartz countertops quote for the kitchen"), trigger: .pull))
        let first = try #require(response.suggestions.first)
        #expect(!response.query.rareTerms.isEmpty)
        #expect(first.unit.kind == .image)
    }
}

@Suite struct PolicyTests {
    @Test func fixedGapHasNoHourlyCapOrFeedbackPenalty() {
        var policy = SurfacePolicy()
        let now = Date()
        #expect(policy.signalDelay(now: now) == 0)
        for n in 0..<20 {
            let time = now.addingTimeInterval(Double(n) * 60)
            #expect(policy.signalDelay(now: time) == 0)
            policy.didSurface(itemIDs: [Int64(n)], topic: "chat", at: time)
            for outcome in Outcome.allCases { policy.record(outcome, itemID: Int64(n), topic: "chat") }
            #expect(policy.signalDelay(now: time.addingTimeInterval(1)) == 59)
            #expect(policy.signalDelay(now: time.addingTimeInterval(60)) == 0)
        }
    }

    @Test func itemDeduplicationSurvivesEditsAndReturningToAConversation() {
        var policy = SurfacePolicy()
        policy.didSurface(itemIDs: [1, 2], topic: "chat-a")
        #expect(!policy.maySuggest(itemID: 1, topic: "chat-a"))
        #expect(policy.maySuggest(itemID: 3, topic: "chat-a"))
        #expect(policy.maySuggest(itemID: 1, topic: "chat-b"))
        policy.didSurface(itemIDs: [1], topic: "chat-b")
        #expect(!policy.maySuggest(itemID: 2, topic: "chat-a"))
        policy.record(.dismissed, itemID: 3, topic: "chat-a")
        #expect(!policy.maySuggest(itemID: 3, topic: "chat-a"))
        #expect(policy.isDismissed(itemID: 3, topic: "chat-a"))
        #expect(!policy.isDismissed(itemID: 3, topic: "chat-b"))
    }

    @Test func searchCanFinishDuringTheSignalGapAndUseTheLatestDraft() {
        let now = Date()
        var policy = SurfacePolicy()
        policy.didSurface(itemIDs: [1], topic: "chat", at: now)
        var schedule = AmbientLookupSchedule()
        schedule.didChange(textEdited: true, at: now.addingTimeInterval(5))
        #expect(schedule.delay(fingerprint: "new draft", topic: "chat", requiredDwell: 5, now: now.addingTimeInterval(7)) == 0)
        #expect(policy.signalDelay(now: now.addingTimeInterval(7)) == 53)
        #expect(policy.maySuggest(itemID: 2, topic: "chat"))
        #expect(policy.signalDelay(now: now.addingTimeInterval(60)) == 0)
    }

    @Test func suppressedAnswersDontLendTheirProbability() {
        func result(_ id: Int64, _ probability: Double?, answered: Double?) -> Suggestion {
            let date = Date(timeIntervalSince1970: 0)
            return Suggestion(item: Item(id: id, source: .file, path: "/demo/\(id)", kind: .document, title: "\(id)", size: 1,
                                         created: date, modified: date, lastUsed: nil),
                              unit: Unit(kind: .text, locator: .whole, text: "text"), reason: "Related", snippet: "text",
                              score: 1, confidence: probability ?? 0,
                              features: Features(cosine: 0.7, daysSinceTouched: 10, probability: probability, answered: answered))
        }
        let policy = SurfacePolicy()
        let lookup = [result(1, 0.98, answered: 0.99), result(2, 0.01, answered: 0.99)]
        #expect(policy.signalable(lookup) { _ in true }.map(\.id) == [1, 2])
        // The answer was already shown or dismissed here: what's left is only 0.01 likely.
        #expect(policy.signalable(lookup) { $0.id != 1 }.isEmpty)
        // Two answers that share the probability can signal together.
        #expect(policy.signalable([result(3, 0.45, answered: 0.9), result(4, 0.45, answered: 0.9)]) { _ in true }.count == 2)
        // Without a decision nothing signals.
        #expect(policy.signalable([result(5, nil, answered: nil)]) { _ in true }.isEmpty)
    }

    @Test func sensitivityMovesThreshold() {
        var settings = SurfacePolicy.Settings()
        #expect(abs(settings.threshold - 0.8) < 0.000_001)
        settings.sensitivity = 0
        let strict = settings.threshold
        settings.sensitivity = 1
        #expect(settings.threshold < strict)
    }
}

@Suite struct JournalTests {
    @Test func computesPrecision() throws {
        let journal = try Journal(url: try temporaryFolder().appending(path: "journal.sqlite"))
        let pull = try journal.log(JournalEntry(mode: .pull, bundleID: "x", fingerprint: "f", dwellSeconds: 0, suggestions: []))
        try journal.record(.opened, entryID: pull, itemID: 1, position: 0)
        let other = try journal.log(JournalEntry(mode: .pull, bundleID: "x", fingerprint: "g", dwellSeconds: 0, suggestions: []))
        try journal.record(.dismissed, entryID: other, itemID: 2, position: 0)
        let stats = try journal.stats(days: 7)
        #expect(stats.pulls == 2)
        #expect(stats.pullPrecisionAt1 == 0.5)
        #expect(stats.useful == 1)
    }
}

@Suite struct ScannerTests {
    @Test func skipsCodeAndLibrary() throws {
        let home = URL(filePath: String(cString: realpath(try temporaryFolder().path, nil)))
        let fm = FileManager.default
        for path in ["Documents/plan.md", "Library/Caches/x.txt", "src/repo/.git/HEAD", "src/repo/README.md",
                     "Documents/node_modules/pkg/readme.md", "Desktop/Screenshot.png", "Documents/notes.xyz"] {
            let url = home.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "content".write(to: url, atomically: true, encoding: .utf8)
        }
        var found: [String] = []
        let scanner = FileScanner(settings: SourceSettings(), home: home.path)
        try scanner.scan { found.append($0.path.replacingOccurrences(of: home.path + "/", with: "")) }
        #expect(Set(found) == ["Documents/plan.md", "Desktop/Screenshot.png"])
        for path in ["Documents/plan.md", "Library/Caches/x.txt", "src/repo/README.md",
                     "Documents/node_modules/pkg/readme.md", "Desktop/Screenshot.png", "Documents/notes.xyz"] {
            #expect((scanner.item(at: home.appending(path: path)) != nil) == found.contains(path))
        }

        var withRepo: [String] = []
        let settings = SourceSettings(includes: [home.appending(path: "src/repo").path], excludes: [home.appending(path: "Desktop").path])
        let includingRepo = FileScanner(settings: settings, home: home.path)
        try includingRepo.scan { withRepo.append($0.path.replacingOccurrences(of: home.path + "/", with: "")) }
        #expect(Set(withRepo) == ["Documents/plan.md", "src/repo/README.md"])
        #expect(includingRepo.item(at: home.appending(path: "src/repo/README.md")) != nil)
        #expect(includingRepo.item(at: home.appending(path: "Desktop/Screenshot.png")) == nil)
    }
}

@Suite struct ScopeTests {
    @Test func skipsDataDumpFolders() throws {
        let home = URL(filePath: String(cString: realpath(FileManager.default.temporaryDirectory.path, nil))).appending(path: "appears-scope-\(UUID().uuidString)")
        let fm = FileManager.default
        let dump = home.appending(path: "Documents/StockData")
        try fm.createDirectory(at: dump, withIntermediateDirectories: true)
        for i in 0...FileScanner.dataFolderThreshold { try "1,2,3".write(to: dump.appending(path: "t\(i).txt"), atomically: true, encoding: .utf8) }
        try "chart".write(to: dump.appending(path: "chart.png"), atomically: true, encoding: .utf8)
        try "my notes".write(to: home.appending(path: "Documents/notes.md"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: home.appending(path: "conductor/x"), withIntermediateDirectories: true)
        try "agent".write(to: home.appending(path: "conductor/x/plan.md"), atomically: true, encoding: .utf8)
        var found: [String] = []
        try FileScanner(settings: SourceSettings(), home: home.path).scan { found.append($0.path.replacingOccurrences(of: home.path + "/", with: "")) }
        #expect(Set(found) == ["Documents/notes.md", "Documents/StockData/chart.png"])
        #expect(FileScanner(settings: SourceSettings(), home: home.path).item(at: dump.appending(path: "t1.txt")) == nil)
    }

    @Test func spotsDataText() {
        #expect(Extractor.looksLikeData(String(repeating: "2024-01-02,131.2,133.9,130.1,132.5,10293\n", count: 40)))
        #expect(!Extractor.looksLikeData(String(repeating: "Dana said the outlet by the window has to move for code. ", count: 20)))
    }
}

@Suite struct NameTests {
    @Test func ignoresTheAppToolsAcronymsAndSentenceStarts() {
        let text = "Ran Codex, Claude, and Gemini on the same PR. Two PRs merged. The API is fine.\nPriya Natarajan booked the offsite."
        let names = QueryBuilder.entities(in: text, ignoring: QueryBuilder.ignoredNames(appName: "Claude"))
        #expect(names.contains("Priya Natarajan"))
        for wrong in ["Ran", "Codex", "Claude", "Gemini", "PR", "PRs", "API"] { #expect(!names.contains(wrong), "\(wrong)") }
    }

    @Test func keepsOneWordNamesSeenMidSentence() {
        let names = QueryBuilder.entities(in: "Joan sent the code. Thanks again to Joan for the cabin.")
        #expect(names.contains("Joan"))
    }

    @Test func splitsStrongAndContextNames() {
        let context = ContextSnapshot(appName: "Claude", windowTitle: "Offsite planning", focusedText: "What did Priya Natarajan say about the venue?",
                                      visibleText: "Earlier we talked with Marcus Bell about the budget.")
        let query = QueryBuilder.build(context)
        #expect(query.entities.contains("Priya Natarajan"))
        #expect(query.contextEntities.contains("Marcus Bell"))
        #expect(!query.entities.contains("Marcus Bell"))
    }
}
