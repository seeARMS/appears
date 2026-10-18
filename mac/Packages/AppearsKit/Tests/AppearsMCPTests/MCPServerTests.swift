import AppearsCore
import CoreGraphics
import Foundation
import Testing

@testable import AppearsMCP

/// `demo/files` in this checkout.
private let demoFiles: URL = {
    var url = URL(filePath: #filePath)
    while url.path != "/" {
        url.deleteLastPathComponent()
        let candidate = url.appending(path: "demo/files")
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate.resolvingSymlinksInPath() }
    }
    fatalError("demo/files not found")
}()

/// An index of demo/files with the hashing embedder: it matches words, not meaning.
/// Images use deterministic metadata, with fixed OCR for the cabin card, so protocol
/// tests do not depend on Vision hardware. Real OCR is exercised by the model suite.
private actor DemoIndex {
    static let shared = DemoIndex()
    private var built: Task<URL, Error>?

    func folder() async throws -> URL {
        if built == nil {
            built = Task {
                let folder = FileManager.default.temporaryDirectory.appending(path: "appears-mcp-tests-\(UUID().uuidString)")
                let embedder = HashingEmbedder()
                let engine = try Engine(folder: folder, embedder: embedder, settings: SourceSettings(notes: false))
                await engine.indexer.setPoliteness(false)
                struct Dates: Decodable { var ages: [String: Double] }
                let ages = try JSONDecoder().decode(Dates.self, from: Data(contentsOf: demoFiles.deletingLastPathComponent().appending(path: "manifest.json"))).ages
                let now = Date()
                try FileScanner(settings: SourceSettings(notes: false), home: demoFiles.path).scan { item in
                    var fixture = item
                    let relative = String(item.path.dropFirst(demoFiles.path.count + 1))
                    if let age = ages[relative] {
                        fixture.created = now.addingTimeInterval(-age * 86_400)
                        fixture.modified = fixture.created
                        fixture.lastUsed = nil
                    }
                    try engine.store.record(fixture, signature: FileScanner.signature(item))
                }
                let card = try #require(try engine.store.item(path: demoFiles.appending(path: "Desktop/IMG_2031.jpg").path))
                // The invented card's content from demo/make-demo.py, before OCR.
                let text = """
                Welcome to Pine Hollow Cabin!
                WiFi: PineHollow-Guest
                Password: trout-meadow-88
                Hot tub: cover back on please
                Trash pickup Tuesday a.m.
                Emergency: Joan (530) 555-0177
                """
                let vector = try await embedder.embed(documents: [EmbeddingDocument(title: card.title, text: text)])[0]
                _ = try engine.store.replaceUnits(itemID: card.id, title: card.title, units: [
                    (AppearsCore.Unit(kind: .text, locator: .whole, text: text), vector),
                    (AppearsCore.Unit(kind: .image, locator: .whole, text: text), vector),
                ])
                // Match the no-OCR fallback on virtual Macs for every other image.
                // Otherwise local Vision results change file-similarity rankings.
                for image in try engine.store.pending(limit: 1_000) where image.kind == .image {
                    let title = "\(image.title) (\((image.folder as NSString).lastPathComponent))"
                    let vector = try await embedder.embed(documents: [.init(title: title, text: image.title)])[0]
                    _ = try engine.store.replaceUnits(itemID: image.id, title: image.title, units: [
                        (AppearsCore.Unit(kind: .text, locator: .whole, text: ""), vector),
                    ])
                }
                try await engine.indexer.indexPending()
                return folder
            }
        }
        return try await built!.value
    }
}

/// File similarity must use stored vectors, independent of language-passage inference.
private struct FileOnlyTestEmbedder: Embedder {
    let base = HashingEmbedder()
    var modelID: String { base.modelID }
    var dimension: Int { base.dimension }
    var supportsImages: Bool { base.supportsImages }
    func embed(queries: [String]) async throws -> [[Float]] { try await base.embed(queries: queries) }
    func embed(documents: [EmbeddingDocument]) async throws -> [[Float]] { try await base.embed(documents: documents) }
    func embed(images: [CGImage]) async throws -> [[Float]] { try await base.embed(images: images) }
    func embed(passages: [EmbeddingDocument]) async throws -> [[Float]] {
        struct UnexpectedPassageInference: Error {}
        throw UnexpectedPassageInference()
    }
}

private func demoIndex(sources: SourceSettings = SourceSettings()) async throws -> AgentIndex {
    AgentIndex(folder: try await DemoIndex.shared.folder(), sources: sources) { HashingEmbedder() }
}

/// Writes `messages` to the server's input one per line, closes it, as a client piping a
/// script would, and returns every line the server wrote, parsed.
private func exchange(_ messages: [String], index: AgentIndex) async throws -> [JSONValue] {
    let input = Pipe()
    let output = Pipe()
    let writer = output.fileHandleForWriting
    let server = MCPServer(index: index, write: { writer.write($0 + Data([0x0A])) })
    let reading = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
    let serving = Task { await server.serve(input.fileHandleForReading) }
    for message in messages { input.fileHandleForWriting.write(Data((message + "\n").utf8)) }
    try input.fileHandleForWriting.close()
    await serving.value
    try writer.close()
    let data = await reading.value
    return try data.split(separator: 0x0A).map { try JSONValue.parse(Data($0)) }
}

private func call(_ id: Int, _ tool: String, _ arguments: String, meta: String = "") -> String {
    #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments)\#(meta)}}"#
}

private let modernMeta = #","_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#

private func response(_ answers: [JSONValue], id: Int) throws -> JSONValue {
    try #require(answers.first { $0["id"] == .int(id) }, "no answer to \(id)")
}

private func results(_ answer: JSONValue) -> [JSONValue] {
    answer["result"]?["structuredContent"]?["results"]?.array ?? []
}

@Suite(.serialized) struct MCPServerTests {
    @Test func initializeListAndAskAboutTheCabinWifi() async throws {
        let answers = try await exchange([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            call(3, "related", #"{"text":"what's the wifi password at the cabin"}"#),
        ], index: try await demoIndex())
        #expect(answers.count == 3, "the notification gets no answer")

        let initialize = try response(answers, id: 1)["result"]
        #expect(initialize?["protocolVersion"] == "2025-11-25")
        #expect(initialize?["serverInfo"]?["name"] == "rs.appea/appears")
        #expect(initialize?["capabilities"]?["tools"] != nil)

        let tools = try response(answers, id: 2)["result"]?["tools"]?.array ?? []
        #expect(tools.compactMap { $0["name"]?.string } == ["related", "related_to_file"])
        #expect(tools.allSatisfy { $0["annotations"]?["readOnlyHint"] == true })

        let related = try response(answers, id: 3)
        #expect(related["result"]?["isError"] == false)
        let top = try #require(results(related).first)
        #expect(top["path"]?.string?.hasSuffix("Desktop/IMG_2031.jpg") == true)
        #expect(top["kind"] == "image")
        #expect(top["snippet"]?.string?.contains("PineHollow") == true)
        let text = related["result"]?["content"]?.array?.first?["text"]?.string ?? ""
        #expect(text.contains("Desktop/IMG_2031.jpg"))
    }

    @Test func speaksBothEras() async throws {
        let answers = try await exchange([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2025-06-18"}}}"#,
            #"{"jsonrpc":"2.0","id":"six","method":"ping"}"#,
            call(7, "related", #"{"text":"cabin wifi password","limit":2}"#, meta: modernMeta),
        ], index: try await demoIndex())

        #expect(try response(answers, id: 1)["result"]?["protocolVersion"] == "2024-11-05")
        #expect(try response(answers, id: 2)["result"]?["protocolVersion"] == "2025-11-25", "an unknown revision gets the newest legacy one")

        let discover = try response(answers, id: 3)["result"]
        #expect(discover?["supportedVersions"] == ["2026-07-28"])
        #expect(discover?["resultType"] == "complete")
        #expect(discover?["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"] == "rs.appea/appears")
        #expect(discover?["ttlMs"]?.int ?? 0 > 0)

        #expect(try response(answers, id: 4)["result"]?["tools"]?.array?.count == 2)

        let unsupported = try response(answers, id: 5)["error"]
        #expect(unsupported?["code"] == .int(MCPServer.unsupportedVersion))
        #expect(unsupported?["data"]?["supported"] == ["2026-07-28"])
        #expect(unsupported?["data"]?["requested"] == "2025-06-18")

        #expect(answers.first { $0["id"] == "six" }?["result"]?["resultType"] == "complete")

        let modern = try response(answers, id: 7)
        #expect(results(modern).count <= 2)
        #expect(results(modern).first?["path"]?.string?.hasSuffix("Desktop/IMG_2031.jpg") == true)
    }

    @Test func reportsErrorsTheWayTheSpecAsks() async throws {
        let answers = try await exchange([
            "{not json",
            #"{"jsonrpc":"2.0","id":1,"method":"resources/subscribe"}"#,
            call(2, "delete_everything", "{}"),
            call(3, "related", #"{"text":"   "}"#),
            #"{"jsonrpc":"2.0","id":4,"result":{}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":99}}"#,
            #"{"id":5,"method":"ping"}"#,
            call(6, "related_to_file", #"{"path":"/nowhere/at/all.pdf"}"#),
        ], index: try await demoIndex())
        #expect(answers.count == 6, "a response and a notification get no answer")

        let parse = try #require(answers.first { $0["error"]?["code"] == .int(MCPServer.parseError) })
        #expect(parse["id"] == .null)
        #expect(try response(answers, id: 1)["error"]?["code"] == .int(MCPServer.methodNotFound))
        #expect(try response(answers, id: 2)["error"]?["code"] == .int(MCPServer.invalidParams))
        // Bad arguments are tool errors, so the model sees them and can try again.
        #expect(try response(answers, id: 3)["result"]?["isError"] == true)
        #expect(answers.contains { $0["error"]?["code"] == .int(MCPServer.invalidRequest) })
        let missing = try response(answers, id: 6)["result"]
        #expect(missing?["isError"] == true)
        #expect(missing?["content"]?.array?.first?["text"]?.string?.contains("hasn't indexed") == true)
    }

    @Test func answersAShortAsk() async throws {
        // One word is too little for the app's context rules on its own; it's phrased as an ask.
        let answers = try await exchange([call(1, "related", #"{"text":"Joan"}"#)], index: try await demoIndex())
        let top = try #require(results(try response(answers, id: 1)).first)
        #expect(top["path"]?.string?.hasSuffix("Desktop/IMG_2031.jpg") == true)
        #expect(top["reason"]?.string?.localizedCaseInsensitiveContains("joan") == true)
    }

    @Test func findsWhatRelatesToAFile() async throws {
        let file = demoFiles.appending(path: "Documents/House/Kitchen measurements.md").path
        // The same file by way of a symlink, as an agent might give it.
        let link = FileManager.default.temporaryDirectory.appending(path: "appears-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: demoFiles.appending(path: "Documents/House"))
        defer { try? FileManager.default.removeItem(at: link) }
        let index = AgentIndex(folder: try await DemoIndex.shared.folder(), sources: SourceSettings()) { FileOnlyTestEmbedder() }
        let answers = try await exchange([
            call(1, "related_to_file", #"{"path":"\#(file)","limit":5}"#),
            call(2, "related_to_file", #"{"path":"file://\#(file.replacingOccurrences(of: " ", with: "%20"))","limit":5}"#),
            call(3, "related_to_file", #"{"path":"\#(link.path)/Kitchen measurements.md","limit":5}"#),
        ], index: index)
        for id in [1, 2, 3] {
            let found = results(try response(answers, id: id)).compactMap { $0["path"]?.string }
            #expect(!found.isEmpty)
            #expect(!found.contains(file), "never the file itself")
            #expect(found.contains { $0.contains("/Documents/House/") }, "\(found)")
        }
    }

    @Test func respectsExcludedFoldersAndNeverShow() async throws {
        let wifi = call(1, "related", #"{"text":"what's the wifi password at the cabin"}"#)
        let excluded = try await exchange([wifi], index: try await demoIndex(sources: SourceSettings(excludes: [demoFiles.appending(path: "Desktop").path])))
        #expect(!results(try response(excluded, id: 1)).contains { $0["path"]?.string?.contains("/Desktop/") == true })

        let noImages = try await exchange([wifi], index: try await demoIndex(sources: SourceSettings(excludedKinds: [.image])))
        #expect(!results(try response(noImages, id: 1)).contains { $0["kind"] == "image" })

        // "Never show this" from the panel, written by the engine while this reader is open.
        let writer = try IndexStore(url: try await DemoIndex.shared.folder().appending(path: "index.sqlite"))
        let card = try #require(try writer.item(path: demoFiles.appending(path: "Desktop/IMG_2031.jpg").path))
        try writer.setNeverShow(itemID: card.id)
        defer { try? writer.setNeverShow(itemID: card.id, false) }
        let blocked = try await exchange([wifi], index: try await demoIndex())
        #expect(!results(try response(blocked, id: 1)).contains { $0["path"]?.string?.hasSuffix("IMG_2031.jpg") == true })
    }

    @Test func recentFilesComeBackUnlessAskedToPreferForgotten() async throws {
        // A note from today that matches closely, and a weaker one from last year.
        let home = FileManager.default.temporaryDirectory.appending(path: "appears-recent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        for (name, text, days) in [
            ("today.txt", "Pine Hollow cabin wifi password", 0.0),
            ("last year.txt", "Pine Hollow cabin wifi password, and notes from that trip about the lake and the drive up", 400.0),
        ] {
            let path = home.appending(path: name).path
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-days * 86_400)], ofItemAtPath: path)
        }
        let data = home.appending(path: ".index")
        let engine = try Engine(folder: data, embedder: HashingEmbedder(), settings: SourceSettings(notes: false))
        try FileScanner(settings: SourceSettings(notes: false), home: home.path).scan { item in
            try engine.store.record(item, signature: FileScanner.signature(item))
        }
        await engine.indexer.setPoliteness(false)
        try await engine.indexer.indexPending()

        let answers = try await exchange([
            call(1, "related", #"{"text":"Pine Hollow cabin wifi password"}"#),
            call(2, "related", #"{"text":"Pine Hollow cabin wifi password","prefer_forgotten":true}"#),
        ], index: AgentIndex(folder: data) { HashingEmbedder() })
        let asked = results(try response(answers, id: 1)).compactMap { $0["title"]?.string }
        let forgotten = results(try response(answers, id: 2)).compactMap { $0["title"]?.string }
        #expect(asked.first == "today.txt", "\(asked)")
        #expect(forgotten.first == "last year.txt", "\(forgotten)")
    }

    @Test func dropsTheAnswerToACancelledCall() async throws {
        let answers = try await exchange([
            call(1, "related", #"{"text":"Lisbon trip itinerary"}"#),
            call(2, "related", #"{"text":"dental claim"}"#),
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2,"reason":"changed my mind"}}"#,
        ], index: try await demoIndex())
        #expect(answers.map { $0["id"] } == [.int(1)])
    }

    @Test func answersABatch() async throws {
        let answers = try await exchange([
            #"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"related","arguments":{"text":"cabin wifi"}}}]"#,
        ], index: try await demoIndex())
        let batch = try #require(answers.first?.array)
        #expect(batch.compactMap { $0["id"]?.int } == [1, 2])
    }
}

@Suite struct ReadOnlyIndexTests {
    /// The engine writes while `appears mcp` reads: a read-only pool sees each commit through
    /// WAL, notices it changed, and can't write.
    @Test func readsBesideTheEngine() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "appears-ro-\(UUID().uuidString)")
        let url = folder.appending(path: "index.sqlite")
        func item(_ name: String) -> Item {
            Item(source: .file, path: "/demo/\(name)", kind: .document, title: name, size: 1, created: .now, modified: .now, lastUsed: nil)
        }
        var engine: IndexStore? = try IndexStore(url: url)
        let (first, _) = try engine!.record(item("a.txt"), signature: "1")
        _ = try engine!.replaceUnits(itemID: first, title: "a.txt", units: [(Unit(kind: .text, locator: .whole, text: "alpha"), [1, 0])])

        var reader: IndexStore! = try IndexStore(url: url, readOnly: true)
        let before = try reader.contentStamp()
        #expect(try reader.item(path: "/demo/a.txt") != nil)

        let (second, _) = try engine!.record(item("b.txt"), signature: "1")
        _ = try engine!.replaceUnits(itemID: second, title: "b.txt", units: [(Unit(kind: .text, locator: .whole, text: "beta"), [0, 1])])
        #expect(try reader.item(path: "/demo/b.txt") != nil, "sees the engine's later commit")
        #expect(try reader.contentStamp() != before)

        // Re-indexing an item reuses the unit ids it deleted; the stamp still moves.
        let middle = try reader.contentStamp()
        var changed = item("b.txt")
        changed.modified = .now.addingTimeInterval(60)
        _ = try engine!.record(changed, signature: "2")
        _ = try engine!.replaceUnits(itemID: second, title: "b.txt", units: [(Unit(kind: .text, locator: .whole, text: "beta 2"), [0, 1])])
        #expect(try reader.contentStamp() != middle)

        #expect(throws: (any Error).self) { try reader.touch(path: "/demo/a.txt") }

        // With everyone gone, a new reader opens it even without the WAL and shared-memory
        // files (macOS's SQLite keeps an empty WAL after closing; a copied index has neither).
        reader = nil
        engine = nil
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        let later = try IndexStore(url: url, readOnly: true)
        #expect(try later.counts().units == 2)
        try? FileManager.default.removeItem(at: folder)
    }
}
