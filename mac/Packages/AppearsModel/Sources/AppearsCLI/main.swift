import AppearsCore
import ArgumentParser
import Foundation
import GemmaEmbedder

/// `appears`: index, ask and evaluate from the terminal, with the same engine the app runs.
/// The terminal needs Full Disk Access to read Notes and protected folders.
@main
struct Appears: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "appears",
        abstract: "Appears from the terminal: build an index, find what relates to some text, run the eval, serve agents.",
        subcommands: [Index.self, Related.self, Eval.self, Stats.self, MCP.self]
    )
}

struct Common: ParsableArguments {
    @Option(help: "Where the index lives.")
    var data: String = FileScanner.realHome + "/Library/Application Support/rs.appea.appears.cli"
    @Option(help: "The model folder (default: mac/Models/appears-model in this checkout).")
    var model: String?
    @Option(help: "gemma (the real model) or hash (a fast stand-in that only matches words).")
    var embedder: String = "gemma"

    func makeEmbedder() async throws -> any Embedder {
        if embedder == "hash" { return HashingEmbedder() }
        return try await GemmaEmbedder.load(from: try modelFolder())
    }

    func modelFolder() throws -> URL { try Self.modelFolder(model) }

    /// `--model`, then `APPEARS_MODEL`, then `mac/Models/appears-model` above the current folder
    /// or this binary, then the app's verified downloaded model cache. Keep the old
    /// bundle fallback for installations made before the lightweight download.
    static func modelFolder(_ model: String?) throws -> URL {
        if let model { return URL(filePath: model) }
        if let path = ProcessInfo.processInfo.environment["APPEARS_MODEL"] { return URL(filePath: path) }
        for start in [FileManager.default.currentDirectoryPath, CommandLine.arguments[0]] {
            var url = URL(filePath: start).standardizedFileURL
            while url.path != "/" {
                for candidate in ["mac/Models/appears-model", "Models/appears-model"] {
                    let folder = url.appending(path: candidate)
                    if FileManager.default.fileExists(atPath: folder.appending(path: "model.safetensors").path) { return folder }
                }
                url.deleteLastPathComponent()
            }
        }
        for applications in ["/Applications", FileScanner.realHome + "/Applications"] {
            let folder = URL(filePath: applications + "/Appears.app/Contents/XPCServices/AppearsEngine.xpc/Contents/Resources/appears-model")
            if FileManager.default.fileExists(atPath: folder.appending(path: "model.safetensors").path) { return folder }
        }
        let descriptor = try ModelDescriptor.bundled()
        if ModelAssets.isInstalled(descriptor) { return ModelAssets.folder(for: descriptor) }
        throw ValidationError("No model found. Finish the model download in Appears, run mac/scripts/fetch-model.sh, or pass --model.")
    }
}

struct Index: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Scan and index (home folder, Notes and Messages with photos by default).")
    @OptionGroup var common: Common
    @Option(help: "Index only this folder instead of the home folder.")
    var root: String?
    @Flag(help: "Skip Apple Notes.")
    var noNotes = false
    @Flag(help: "Skip Messages and their photos.")
    var noMessages = false

    func run() async throws {
        let embedder = try await common.makeEmbedder()
        var settings = SourceSettings(notes: !noNotes, messages: !noMessages)
        let engine: Engine
        if let root {
            let folder = URL(filePath: root).standardizedFileURL.path
            settings.includes = [folder]
            engine = try Engine(folder: URL(filePath: common.data), embedder: embedder, settings: settings)
            // Index the folder alone: a scanner rooted there.
            await engine.indexer.setPoliteness(false)
            try await scanOnly(folder, engine: engine, settings: settings)
        } else {
            engine = try Engine(folder: URL(filePath: common.data), embedder: embedder, settings: settings)
            await engine.indexer.setPoliteness(false)
            print("Scanning \(FileScanner.realHome)…")
            let found = try await engine.indexer.scanFiles()
            let notes = try await engine.indexer.scanNotes()
            let messages = try await engine.indexer.scanMessages()
            print("Found \(found) files, \(notes) notes and \(messages) Messages items.")
        }
        let started = Date()
        await engine.indexer.setProgressHandler { progress in
            if progress.done % 25 == 0, progress.done > 0 {
                print("  \(progress.done)/\(progress.total)  (\(Int(Date().timeIntervalSince(started)))s)")
            }
        }
        let indexed = try await engine.indexer.indexPending()
        let counts = try engine.store.counts()
        print("Indexed \(indexed) items in \(Int(Date().timeIntervalSince(started)))s. Index: \(counts.indexedTotal) items, \(counts.units) units, \(counts.unreadable) unreadable.")
    }

    func scanOnly(_ folder: String, engine: Engine, settings: SourceSettings) async throws {
        let scanner = FileScanner(settings: SourceSettings(excludedKinds: settings.excludedKinds, notes: false), home: folder)
        var found = 0
        try scanner.scan { item in
            try engine.store.record(item, signature: FileScanner.signature(item))
            found += 1
        }
        print("Found \(found) files in \(folder).")
    }
}

struct Related: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "What you already have that relates to some text.")
    @OptionGroup var common: Common
    @Argument(help: "The text (what you'd be looking at). Use --file for a file's contents.")
    var text: String?
    @Option(help: "Read the context from a file.")
    var file: String?
    @Option(help: "The window title.")
    var title: String = ""
    @Option(help: "How many results.")
    var limit: Int = 5

    func run() async throws {
        let body = try file.map { try String(contentsOfFile: $0, encoding: .utf8) } ?? text ?? ""
        guard !body.isEmpty else { throw ValidationError("Give some text or --file.") }
        let embedder = try await common.makeEmbedder()
        let engine = try Engine(folder: URL(filePath: common.data), embedder: embedder, settings: SourceSettings())
        var context = ContextSnapshot.text(body, title: title)
        context.documentPath = file.map { URL(filePath: $0).standardizedFileURL.path }
        let response = try await engine.recall.run(RecallRequest(context: context, trigger: .pull, limit: limit))
        print("Query: \(response.query.denseCharacters) chars; entities \(response.query.entities); rare \(response.query.rareTerms); \(Int(response.milliseconds)) ms")
        for (index, suggestion) in response.suggestions.enumerated() {
            let f = suggestion.features
            print("\(index + 1). \(suggestion.item.title)  [\(suggestion.item.kind.label)]  confidence \(String(format: "%.2f", suggestion.confidence))")
            print("   \(suggestion.reason)")
            print("   \(suggestion.item.path)")
            print("   cos \(String(format: "%.3f", f.cosine)) z \(String(format: "%.1f", f.zScore)) agree \(f.agreement) entity \(f.entityHit) intent \(f.recallIntent) days \(Int(f.daysSinceTouched)) forgotten \(String(format: "%.2f", f.forgotten)) novelty \(String(format: "%.2f", f.novelty))")
            if let line = suggestion.line {
                print("   ⟶ \(line.text.replacingOccurrences(of: "\n", with: " / "))")
            } else if !suggestion.snippet.isEmpty {
                print("   “\(suggestion.snippet)”")
            }
        }
        if response.suggestions.isEmpty { print("Nothing.") }
    }
}

struct Stats: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "The journal's numbers (pass the app's data folder to see the app's).")
    @Option(help: "The folder holding journal.sqlite.")
    var data: String = FileScanner.realHome + "/Library/Containers/rs.appea.appears.engine/Data/Library/Application Support/Appears"
    @Option(help: "Days to look back.")
    var days: Int = 7

    func run() throws {
        let journal = try Journal(url: URL(filePath: data).appending(path: "journal.sqlite"))
        let stats = try journal.stats(days: days)
        func percent(_ value: Double?) -> String { value.map { "\(Int(($0 * 100).rounded()))%" } ?? "–" }
        print("""
            Last \(days) days
              pulls \(stats.pulls), ambient \(stats.ambient), shadow \(stats.shadow)
              useful \(stats.useful) (\(String(format: "%.1f", stats.usefulPerDay))/day), dismissed \(stats.dismissed), ignored \(stats.ignored)
              pull precision@1 \(percent(stats.pullPrecisionAt1)), @3 \(percent(stats.pullPrecisionAt3))
              ambient precision \(percent(stats.ambientPrecision)), shadow precision \(percent(stats.shadowPrecision))
            """)
    }
}

struct Eval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Index demo/files in a temporary folder and score demo/scenarios.json.",
        discussion: "Prints recall@3, MRR, how often a forgotten hit is first, and the false-surface rate on negative scenarios."
    )
    @OptionGroup var common: Common
    @Option(help: "The demo folder (default: demo/ in this checkout).")
    var demo: String?
    @Option(help: "The ambient sensitivity (0–1) to judge false surfaces with.")
    var sensitivity: Double = 0.5
    @Flag(help: "Print every result.")
    var verbose = false
    @Option(help: "Results per scenario (recall is still judged on the top 3).")
    var limit: Int = 3
    @Option(help: "Only scenarios whose name contains this.")
    var only: String?

    struct Scenarios: Decodable {
        struct Scenario: Decodable {
            var name: String
            var app: String
            var title: String
            var recipients: [String]?
            /// Calendar scenarios: the event's location.
            var location: String?
            var focused: String?
            var visible: String?
            var document: String?
            var expect: [String]?
            var never: [String]?
            /// Text the top result's matched line must contain (the context asks for a value).
            var line: String?
        }
        var scenarios: [Scenario]
        var negative: [Scenario]
    }

    struct Manifest: Decodable { var ages: [String: Double] }

    func demoFolder() throws -> URL {
        if let demo { return URL(filePath: demo) }
        var url = URL(filePath: FileManager.default.currentDirectoryPath)
        while url.path != "/" {
            let candidate = url.appending(path: "demo/scenarios.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return url.appending(path: "demo") }
            url.deleteLastPathComponent()
        }
        throw ValidationError("Run from the repository, or pass --demo.")
    }

    func run() async throws {
        let demo = try demoFolder()
        let scenarios = try JSONDecoder().decode(Scenarios.self, from: Data(contentsOf: demo.appending(path: "scenarios.json")))
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: demo.appending(path: "manifest.json")))

        // A copy of the demo files with their modification dates set from the manifest.
        let work = FileManager.default.temporaryDirectory.appending(path: "appears-eval-\(UUID().uuidString)")
        let home = URL(filePath: String(cString: realpath(work.deletingLastPathComponent().path, nil))).appending(path: work.lastPathComponent)
        try FileManager.default.copyItem(at: demo.appending(path: "files"), to: home)
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        for (path, age) in manifest.ages {
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age * 86_400)], ofItemAtPath: home.appending(path: path).path)
        }

        let embedder = try await common.makeEmbedder()
        let store = try IndexStore(url: home.appending(path: ".appears/index.sqlite"))
        let vectors = VectorIndex(dimension: embedder.dimension)
        let indexer = Indexer(store: store, vectors: vectors, embedder: embedder, settings: SourceSettings(notes: false))
        await indexer.setPoliteness(false)
        let started = Date()
        try FileScanner(settings: SourceSettings(notes: false), home: home.path).scan { item in
            try store.record(item, signature: FileScanner.signature(item))
        }
        let indexed = try await indexer.indexPending()
        print("Indexed \(indexed) demo files in \(String(format: "%.1f", Date().timeIntervalSince(started)))s with \(embedder.modelID).\n")

        var recall = Recall(store: store, vectors: vectors, embedder: embedder)
        recall.settings = RankingSettings()
        var policy = SurfacePolicy.Settings()
        policy.sensitivity = sensitivity
        let threshold = policy.threshold

        // A "Calendar" scenario is an upcoming event (title, attendees as recipients, location,
        // notes as visible), made into a context the way the app does it. Events the app wouldn't
        // look at (nobody else, no notes) find nothing.
        func event(_ s: Scenarios.Scenario) -> CalendarEvent? {
            guard s.app == CalendarEvent.appName else { return nil }
            return CalendarEvent(
                id: s.name, title: s.title, start: Date().addingTimeInterval(600), end: Date().addingTimeInterval(2_400),
                attendees: (s.recipients ?? []).map(CalendarEvent.Attendee.init(recipient:)),
                location: s.location ?? "", notes: s.visible ?? ""
            )
        }
        func related(_ s: Scenarios.Scenario, trigger: Trigger, limit: Int) async throws -> RecallResponse {
            if let event = event(s) {
                return try await recall.run(RecallRequest(context: event.isWorthLooking ? event.snapshot() : .text(""), trigger: .ambient, limit: limit))
            }
            return try await recall.run(RecallRequest(context: context(s), trigger: trigger, limit: limit))
        }
        func context(_ s: Scenarios.Scenario) -> ContextSnapshot {
            ContextSnapshot(
                appName: s.app, bundleID: "eval.\(s.app)", windowTitle: s.title,
                documentPath: s.document.map { home.appending(path: $0).path }, focusedText: s.focused ?? "",
                visibleText: s.visible ?? "", recipients: s.recipients ?? [], origin: .text
            )
        }
        func short(_ path: String) -> String { path.replacingOccurrences(of: home.path + "/", with: "") }
        func describe(_ f: Features) -> String {
            "[cos \(String(format: "%.3f", f.cosine)) z \(String(format: "%.1f", f.zScore))\(f.agreement ? " agree" : "")\(f.entityHit ? " entity" : "")\(f.recallIntent ? " intent" : "")]"
        }

        var recallSum = 0.0, reciprocal = 0.0, ambientHits = 0, violations = 0
        var linesRight = 0, linesExpected = 0, linesUnexpected = 0
        var times: [Double] = []
        for scenario in scenarios.scenarios where only.map({ scenario.name.localizedCaseInsensitiveContains($0) }) ?? true {
            let response = try await related(scenario, trigger: .pull, limit: max(limit, 3))
            times.append(response.milliseconds)
            let paths = response.suggestions.prefix(3).map { short($0.item.path) }
            let expected = scenario.expect ?? []
            let found = expected.filter(paths.contains)
            recallSum += expected.isEmpty ? 1 : Double(found.count) / Double(min(expected.count, 3))
            if let rank = paths.firstIndex(where: expected.contains) { reciprocal += 1 / Double(rank + 1) }
            if let top = response.suggestions.first, expected.contains(short(top.item.path)), top.confidence >= threshold { ambientHits += 1 }
            violations += (scenario.never ?? []).filter(paths.contains).count
            let mark = found.count == min(expected.count, 3) ? "✓" : (found.isEmpty ? "✗" : "~")
            print("\(mark) \(scenario.name): \(found.count)/\(min(expected.count, 3)) found, top confidence \(String(format: "%.2f", response.confidence))")
            let topLine = response.suggestions.first?.line?.text
            if let line = scenario.line {
                linesExpected += 1
                let right = topLine?.contains(line) == true
                if right { linesRight += 1 }
                print("    \(right ? "✓" : "✗") line: \(topLine?.replacingOccurrences(of: "\n", with: " / ") ?? "none") (expected “\(line)”)")
            } else if let topLine {
                linesUnexpected += 1
                print("    ✗ line where none was expected: \(topLine.replacingOccurrences(of: "\n", with: " / "))")
            }
            if verbose || found.count < min(expected.count, 3) {
                for s in response.suggestions {
                    print("    \(expected.contains(short(s.item.path)) ? "+" : "-") \(short(s.item.path))  \(String(format: "%.2f", s.confidence))  \(s.reason)  \(describe(s.features))")
                }
            }
        }
        var falseSurfaces = 0
        print("")
        for scenario in scenarios.negative {
            let response = try await related(scenario, trigger: .ambient, limit: 3)
            let surfaced = response.confidence >= threshold
            if surfaced { falseSurfaces += 1 }
            let skipped = event(scenario).map { !$0.isWorthLooking } ?? false
            print("\(surfaced ? "✗" : "✓") (negative) \(scenario.name): \(skipped ? "not looked at (nobody else, no notes)" : "top confidence \(String(format: "%.2f", response.confidence))")\(surfaced ? " — would interrupt" : "")")
            if verbose || surfaced {
                for s in response.suggestions { print("    \(short(s.item.path))  \(String(format: "%.2f", s.confidence))  \(s.reason)  \(describe(s.features))") }
            }
        }
        let n = Double(scenarios.scenarios.count)
        print("""

            recall@3          \(String(format: "%.2f", recallSum / n))
            MRR               \(String(format: "%.2f", reciprocal / n))
            ambient hits      \(ambientHits)/\(scenarios.scenarios.count) (top result right and confident at threshold \(String(format: "%.2f", threshold)))
            false surfaces    \(falseSurfaces)/\(scenarios.negative.count)
            open file shown   \(violations) (must be 0)
            matched lines     \(linesRight)/\(linesExpected) right, \(linesUnexpected) where none was expected
            median latency    \(Int(times.sorted()[times.count / 2])) ms
            """)
    }
}
