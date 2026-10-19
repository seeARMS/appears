import AppearsCore
import AppearsMCP
import ArgumentParser
import Foundation
import GemmaEmbedder

/// `appears mcp`: a Model Context Protocol server on stdin and stdout, so local agents can ask
/// what you already have about something. It runs only when an agent you set up starts it.
struct MCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Let local agents ask what you already have, over MCP (stdio).",
        discussion: """
            An agent you configure (Claude Code, Claude desktop, Codex) starts this and talks to it \
            over stdin and stdout. It reads the Appears app's index, read-only, beside the running \
            app, and loads the model on the first question. It sends nothing anywhere and stores \
            nothing; the agent may send what it reads to its model provider.

            Set up: claude mcp add appears -- \(CommandLine.arguments.first ?? "appears") mcp
            """
    )

    /// Where the app's engine keeps its index, in its sandbox container.
    static let appData = FileScanner.realHome + "/Library/Containers/rs.appea.appears.engine/Data/Library/Application Support"

    @Option(help: "The index folder to read, such as one made by `appears index --data` (default: the Appears app's index).")
    var data: String?
    @Flag(help: "Read the app's demo index, the one `Appears.app -demo` makes, instead.")
    var demo = false
    @Option(help: "The model folder (default: mac/Models/appears-model in this checkout, then the one inside Appears.app).")
    var model: String?
    @Option(help: "gemma (the real model) or hash (a fast stand-in that only matches words; for an index made with it).")
    var embedder: String = "gemma"
    @Option(help: "The decision model folder (default: the one in this checkout, else the app's download). \"none\" leaves results without confidence.")
    var decider: String?

    func run() async throws {
        // stdout carries protocol messages and nothing else. Keep the real stdout for them and
        // point file descriptor 1 at stderr, so a stray print from any library can't corrupt it.
        let messages = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        // A client that hangs up mid-answer: stop quietly rather than die on SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        let log: @Sendable (String) -> Void = { FileHandle.standardError.write(Data("appears mcp: \($0)\n".utf8)) }

        let folder = URL(filePath: data ?? Self.appData + (demo ? "/Appears-Demo" : "/Appears")).standardizedFileURL
        // The app's own settings: Exclude folders, kinds and Notes, as the app applies them.
        let sources = UserDefaults(suiteName: "rs.appea.appears")?.data(forKey: "sources")
            .flatMap { try? JSONDecoder().decode(SourceSettings.self, from: $0) } ?? SourceSettings()
        let kind = embedder
        let model = model
        if kind != "hash", (try? Common.modelFolder(model)) == nil { log("no model found; pass --model") }

        let decider = Common.decider(self.decider)
        log(decider == nil ? "no decision model found: results carry no confidence" : "decision model found")
        let index = AgentIndex(folder: folder, sources: sources, decider: decider) {
            if kind == "hash" { return HashingEmbedder() }
            let started = Date()
            let embedder = try await GemmaEmbedder.load(from: try Common.modelFolder(model))
            log("model loaded in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
            return embedder
        }
        let server = MCPServer(index: index, write: { line in
            do {
                try messages.write(contentsOf: line + Data([0x0A]))
            } catch {
                // The agent closed its end: nobody is listening.
                Foundation.exit(0)
            }
        }, log: log)
        log("ready, reading \(folder.path)")
        await server.serve(FileHandle.standardInput)
    }
}
