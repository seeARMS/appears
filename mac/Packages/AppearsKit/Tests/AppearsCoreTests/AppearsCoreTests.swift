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
    @Test func ranksRecentLowerWithoutHidingIt() async throws {
        let (recall, _, _) = try await makeIndex([
            ("quote.txt", "Ruiz Builders quote for kitchen cabinets and countertops, $18,400", 400),
            ("notes-today.txt", "Kitchen cabinets countertops quote, Ruiz Builders, edited today", 0.5),
            ("hiking.txt", "Zion hiking itinerary for three days, Angels Landing permit", 300),
        ])
        let response = try await recall.run(RecallRequest(
            context: .text("Replying to Ruiz Builders about the kitchen cabinets and countertops quote"), trigger: .pull
        ))
        #expect(response.suggestions.first?.item.title == "quote.txt")
        // Recent things still show when you ask, just lower.
        let recent = try #require(response.suggestions.first { $0.item.title == "notes-today.txt" })
        #expect(recent.score < response.suggestions[0].score)
        // On its own, Appears needs much more evidence for something you just touched.
        let ambient = try await recall.run(RecallRequest(
            context: .text("Replying to Ruiz Builders about the kitchen cabinets and countertops quote"), trigger: .ambient
        ))
        let ambientRecent = try #require(ambient.suggestions.first { $0.item.title == "notes-today.txt" })
        #expect(ambientRecent.confidence <= recent.confidence * 0.5 + 1e-9)
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
        #expect(first.features.entityHit)
        // The same name only elsewhere in the window still explains the match, but counts for less.
        let background = try #require(try await recall.run(RecallRequest(context: .text("Email to Dana Ruiz about next week"), trigger: .pull)).suggestions.first)
        #expect(background.reason.hasPrefix("Mentions Dana Ruiz"))
        #expect(!background.features.entityHit)
    }

    @Test func recallIntentOnlyLiftsAClearMatch() throws {
        // A match that stands out: asking your memory makes Appears surer of it.
        var clear = Features(cosine: 0.75, zScore: 4.5, agreement: true, entityHit: false, daysSinceTouched: 400, fused: 0.03, forgotten: 1, novelty: 1)
        let plain = Confidence.estimate(clear)
        clear.recallIntent = true
        #expect(Confidence.estimate(clear) > plain)
        // Nothing stands out ("what's the weather again?"): asking changes nothing.
        var weak = Features(cosine: 0.64, zScore: 2.4, agreement: false, entityHit: false, daysSinceTouched: 400, fused: 0.02, forgotten: 1, novelty: 1)
        let weakPlain = Confidence.estimate(weak)
        weak.recallIntent = true
        #expect(Confidence.estimate(weak) == weakPlain)
        // Journal rows written before the signal existed still decode.
        let old = #"{"cosine":0.7,"zScore":3,"agreement":true,"entityHit":false,"daysSinceTouched":10,"fused":0.02,"forgotten":0.8,"novelty":1}"#
        #expect(try !JSONDecoder().decode(Features.self, from: Data(old.utf8)).recallIntent)
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
        #expect(first.features.agreement)
    }
}

@Suite struct PolicyTests {
    @Test func waitsForDwellAndBacksOff() {
        var policy = SurfacePolicy()
        let now = Date()
        #expect(policy.mayLook(dwell: 5, fingerprint: "a", now: now) == .wait("dwell"))
        #expect(policy.mayLook(dwell: 20, fingerprint: "a", now: now) == .show)
        policy.didSurface(fingerprint: "a", at: now)
        #expect(policy.mayLook(dwell: 20, fingerprint: "a", now: now) == .wait("already shown here"))
        #expect(policy.mayLook(dwell: 20, fingerprint: "b", now: now.addingTimeInterval(60)) == .wait("backoff"))
        #expect(policy.mayLook(dwell: 20, fingerprint: "b", now: now.addingTimeInterval(400)) == .show)
        policy.record(.dismissed)
        #expect(policy.mayLook(dwell: 20, fingerprint: "b", now: now.addingTimeInterval(400)) == .wait("backoff"))
    }

    @Test func sensitivityMovesThreshold() {
        var settings = SurfacePolicy.Settings()
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
        FileScanner(settings: SourceSettings(), home: home.path).scan { found.append($0.path.replacingOccurrences(of: home.path + "/", with: "")) }
        #expect(Set(found) == ["Documents/plan.md", "Desktop/Screenshot.png"])

        var withRepo: [String] = []
        let settings = SourceSettings(includes: [home.appending(path: "src/repo").path], excludes: [home.appending(path: "Desktop").path])
        FileScanner(settings: settings, home: home.path).scan { withRepo.append($0.path.replacingOccurrences(of: home.path + "/", with: "")) }
        #expect(Set(withRepo) == ["Documents/plan.md", "src/repo/README.md"])
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
        FileScanner(settings: SourceSettings(), home: home.path).scan { found.append($0.path.replacingOccurrences(of: home.path + "/", with: "")) }
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
