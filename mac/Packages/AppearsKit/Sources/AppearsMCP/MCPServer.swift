import AppearsCore
import Foundation

/// A Model Context Protocol server over stdio, for `appears mcp`: newline-delimited JSON-RPC
/// 2.0 in, the same out. Local agents (Claude Code, Claude desktop, Codex) start it and ask
/// what the user already has about something. No sockets, no HTTP: the agent's own process
/// pipes are the only channel.
///
/// It speaks both eras of the protocol, as heade.rs's server does (seeARMS/headers,
/// `src/lib/mcp.ts`). 2026-07-28 is stateless: no `initialize`, a `server/discover` method,
/// the version in every request's `_meta`, and `resultType` on every result. Clients on
/// 2025-11-25 and earlier open with `initialize`, and the extra result fields are harmless
/// to them.
public actor MCPServer {
    /// The stateless revision, and the ones before it that open with `initialize`, newest first.
    public static let stateless = "2026-07-28"
    public static let legacy = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    static let name = "rs.appea/appears"
    static let title = "Appears"
    /// Keep in step with VERSION and `MARKETING_VERSION` in mac/project.yml.
    static let version = "0.1.0"
    /// At most 100 characters, for a server card or registry listing.
    static let description = "Find what you already have on your Mac about anything: files, PDFs, screenshots and notes."
    static let website = "https://appea.rs"
    static let instructions = """
        Appears searches the user's own files on this Mac (documents, PDFs, images and screenshots, \
        Apple Notes) with an index and a model that run on the Mac. Call related with a short \
        description of what you're looking for, or with the text you're working on, to find what the \
        user already has about it; call related_to_file to find what relates to one file. Results are \
        paths with why each matched and the matching text. They come from the user's private files, \
        so use only what the task needs.
        """

    private static let meta = "io.modelcontextprotocol/"
    /// How long clients may keep the tool list and the server's description.
    private static let ttl = 24 * 3600 * 1000

    // JSON-RPC and MCP error codes.
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let unsupportedVersion = -32022

    private let index: AgentIndex
    private let write: @Sendable (Data) -> Void
    private let log: @Sendable (String) -> Void
    /// Tool calls in progress, by request id, for cancellation and for finishing at end of input.
    private var running: [JSONValue: Task<Void, Never>] = [:]
    private var cancelled: Set<JSONValue> = []
    /// Tool calls run one at a time (the model runs on the GPU); everything else answers at once.
    private var lastTool: Task<Void, Never>?

    /// `write` gets one message at a time, without its newline. `log` is for stderr: never
    /// pass it query text, results or anything from a file.
    public init(index: AgentIndex, write: @escaping @Sendable (Data) -> Void, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.index = index
        self.write = write
        self.log = log
    }

    /// Answers messages from `input` until it closes, then waits for calls still running.
    public func serve(_ input: FileHandle) async {
        var line = Data()
        do {
            // Split on newline bytes only: JSON may hold U+2028 and other line separators
            // inside strings, which `AsyncLineSequence` would also split on.
            for try await byte in input.bytes {
                if byte == 0x0A {
                    receive(line)
                    line.removeAll(keepingCapacity: true)
                } else {
                    line.append(byte)
                }
            }
            if !line.isEmpty { receive(line) }
        } catch {
            log("Reading input failed: \(error.localizedDescription)")
        }
        while let task = running.values.first { await task.value }
    }

    /// One line of input.
    func receive(_ line: Data) {
        let trimmed = line.last == 0x0D ? line.dropLast() : line
        guard trimmed.contains(where: { ![0x20, 0x09].contains($0) }) else { return }
        guard let message = try? JSONValue.parse(Data(trimmed)) else {
            send(Self.failure(.null, Self.parseError, "Parse error"))
            return
        }
        // Batches left the spec in 2025-06-18, but older clients may send them.
        if case .array(let batch) = message {
            guard !batch.isEmpty else { return send(Self.failure(.null, Self.invalidRequest, "Empty batch")) }
            let key = JSONValue.string("batch-\(UUID().uuidString)")
            let previous = lastTool
            let task = Task {
                await previous?.value
                var answers: [JSONValue] = []
                for message in batch {
                    if let answer = await self.answer(message) { answers.append(answer) }
                }
                self.finish(key, answers.isEmpty ? nil : .array(answers))
            }
            lastTool = task
            running[key] = task
            return
        }
        guard let object = message.object, object["method"]?.string == "tools/call", let id = object["id"],
              object["jsonrpc"]?.string == "2.0"
        else {
            if let answer = answerNow(message) { send(answer) }
            return
        }
        // Tool calls run in turn, off the read loop, so pings and cancellations still get through.
        let previous = lastTool
        let task = Task {
            await previous?.value
            let answer = Task.isCancelled ? nil : await self.answer(message)
            self.finish(id, answer)
        }
        lastTool = task
        running[id] = task
    }

    private func finish(_ id: JSONValue, _ answer: JSONValue?) {
        running[id] = nil
        // A cancelled request gets no further messages.
        if cancelled.remove(id) == nil, let answer { send(answer) }
    }

    private func send(_ message: JSONValue) {
        write(message.line())
    }

    // MARK: - Answering

    /// The answer to any message, waiting for a tool call if it is one. Nil for notifications.
    func answer(_ message: JSONValue) async -> JSONValue? {
        guard let object = message.object, object["method"]?.string == "tools/call", let id = object["id"],
              validID(id), versionError(object, id: id) == nil
        else { return answerNow(message) }
        let params = object["params"]?.object ?? [:]
        guard let name = params["name"]?.string, Tools.names.contains(name) else {
            return Self.failure(id, Self.invalidParams, "Unknown tool: \(params["name"]?.string ?? "(none)")")
        }
        let started = Date()
        let answer = await Tools.call(name, arguments: params["arguments"]?.object ?? [:], index: index)
        let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        // Counts and timings only: never the question, the results or anything from a file.
        if answer.isError {
            log("\(name): returned an error to the agent after \(milliseconds) ms")
        } else {
            log("\(name): \(answer.structured?["results"]?.array?.count ?? 0) results in \(milliseconds) ms")
        }
        return Self.result(id, answer.json.object ?? [:])
    }

    /// The answer to anything but a tool call, which needs no waiting. Nil for notifications.
    func answerNow(_ message: JSONValue) -> JSONValue? {
        guard let object = message.object, object["jsonrpc"]?.string == "2.0" else {
            return Self.failure(.null, Self.invalidRequest, "Invalid request")
        }
        // A response to something this server never asked: nothing to answer.
        guard let method = object["method"]?.string else { return nil }
        let params = object["params"]?.object ?? [:]
        guard let id = object["id"] else {
            notification(method, params: params)
            return nil
        }
        guard validID(id) else { return Self.failure(.null, Self.invalidRequest, "Request ids are strings or integers") }
        if let error = versionError(object, id: id) { return error }

        switch method {
        case "server/discover":
            log("server/discover (\(Self.stateless)) from \(Self.client(params["_meta"]?[Self.meta + "clientInfo"]))")
            return Self.result(id, [
                "supportedVersions": [.string(Self.stateless)],
                "capabilities": ["tools": [:]],
                "instructions": .string(Self.instructions),
                "ttlMs": .int(Self.ttl),
                "cacheScope": "public",
            ])
        case "initialize":
            let asked = params["protocolVersion"]?.string ?? ""
            let version = Self.legacy.contains(asked) ? asked : Self.legacy[0]
            log("initialize (\(version)) from \(Self.client(params["clientInfo"]))")
            return Self.result(id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": [
                    "name": .string(Self.name), "title": .string(Self.title), "version": .string(Self.version),
                    "description": .string(Self.description), "websiteUrl": .string(Self.website),
                ],
                "instructions": .string(Self.instructions),
            ])
        // Gone from 2026-07-28, answered for the clients before it.
        case "ping":
            return Self.result(id, [:])
        case "tools/list":
            return Self.result(id, ["tools": .array(Tools.list), "ttlMs": .int(Self.ttl), "cacheScope": "public"])
        case "tools/call":
            // Only reached from `answer(_:)` when the request is malformed.
            return Self.failure(id, Self.invalidParams, "Unknown tool: \(params["name"]?.string ?? "(none)")")
        // Empty rather than unknown, for clients that ask regardless of capabilities.
        case "resources/list":
            return Self.result(id, ["resources": [], "ttlMs": .int(Self.ttl), "cacheScope": "public"])
        case "resources/templates/list":
            return Self.result(id, ["resourceTemplates": [], "ttlMs": .int(Self.ttl), "cacheScope": "public"])
        case "prompts/list":
            return Self.result(id, ["prompts": [], "ttlMs": .int(Self.ttl), "cacheScope": "public"])
        default:
            return Self.failure(id, Self.methodNotFound, "Method not found: \(method)")
        }
    }

    private func notification(_ method: String, params: [String: JSONValue]) {
        // notifications/initialized and the rest need nothing.
        guard method == "notifications/cancelled", let id = params["requestId"], let task = running[id] else { return }
        cancelled.insert(id)
        task.cancel()
    }

    /// Ids are strings or integers, never null.
    private func validID(_ id: JSONValue) -> Bool {
        switch id {
        case .string, .int: true
        default: false
        }
    }

    /// 2026-07-28 puts the version in every request's `_meta`. A request without it is from a
    /// client on an earlier revision, served as such.
    private func versionError(_ object: [String: JSONValue], id: JSONValue) -> JSONValue? {
        guard let version = object["params"]?["_meta"]?[Self.meta + "protocolVersion"] else { return nil }
        guard version.string != Self.stateless else { return nil }
        return Self.failure(
            id, Self.unsupportedVersion, "Unsupported protocol version: \(version.string ?? "(not a string)")",
            data: ["supported": [.string(Self.stateless)], "requested": version]
        )
    }

    /// "claude-code 2.1.0" from a client's { name, version }, for the log.
    static func client(_ info: JSONValue?) -> String {
        guard let name = info?["name"]?.string else { return "an unnamed client" }
        return String((info?["version"]?.string.map { "\(name) \($0)" } ?? name).prefix(80))
    }

    // MARK: - Messages

    /// What every result carries: 2026-07-28 wants `resultType` and the server's name on each.
    static func result(_ id: JSONValue, _ value: [String: JSONValue]) -> JSONValue {
        var result = value
        result["resultType"] = "complete"
        result["_meta"] = [meta + "serverInfo": ["name": .string(name), "version": .string(version)]]
        return ["jsonrpc": "2.0", "id": id, "result": .object(result)]
    }

    static func failure(_ id: JSONValue, _ code: Int, _ message: String, data: JSONValue? = nil) -> JSONValue {
        var error: [String: JSONValue] = ["code": .int(code), "message": .string(message)]
        if let data { error["data"] = data }
        return ["jsonrpc": "2.0", "id": id, "error": .object(error)]
    }
}
