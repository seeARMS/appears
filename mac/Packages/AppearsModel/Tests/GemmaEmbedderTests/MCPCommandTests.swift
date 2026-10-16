import Foundation
import Testing

/// The `appears` binary: `APPEARS_BIN` (with xcodebuild, `TEST_RUNNER_APPEARS_BIN`), or the one
/// built beside these tests by `xcodebuild test -scheme AppearsModel-Package`.
enum AppearsBinary {
    static let url: URL? = {
        if let path = ProcessInfo.processInfo.environment["APPEARS_BIN"] { return URL(filePath: path) }
        for bundle in Bundle.allBundles where bundle.bundleURL.pathExtension == "xctest" {
            let candidate = bundle.bundleURL.deletingLastPathComponent().appending(path: "appears")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }()
}

/// `appears mcp` as an agent runs it: its own process, the real model, a script on stdin.
/// This covers what the in-process tests in AppearsKit can't: that nothing but protocol
/// messages reaches stdout once MLX and the model are loaded, and that stderr never gets
/// the question.
@Suite(.enabled(if: ModelFolder.exists && AppearsBinary.url != nil, "Needs the model and the appears binary"), .serialized)
struct MCPCommandTests {
    @discardableResult
    private func run(_ binary: URL, _ arguments: [String], input: String = "") async throws -> (stdout: Data, stderr: Data, status: Int32) {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let errors = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (out, await errors.value, process.terminationStatus)
    }

    @Test func answersTheCabinQuestionOverStdio() async throws {
        let binary = try #require(AppearsBinary.url)
        var demo = URL(filePath: #filePath)
        while !FileManager.default.fileExists(atPath: demo.appending(path: "demo/files").path) { demo.deleteLastPathComponent() }
        let data = FileManager.default.temporaryDirectory.appending(path: "appears-mcp-command-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: data) }

        let indexed = try await run(binary, ["index", "--root", demo.appending(path: "demo/files").path, "--data", data.path, "--no-notes", "--no-messages", "--model", ModelFolder.url.path])
        #expect(indexed.status == 0)

        let question = "what's the wifi password at the cabin"
        let script = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"related","arguments":{"text":"\#(question)"}}}"#,
        ].joined(separator: "\n") + "\n"
        let served = try await run(binary, ["mcp", "--data", data.path, "--model", ModelFolder.url.path], input: script)
        #expect(served.status == 0)

        // Every line on stdout is a JSON-RPC message, and there's one per request.
        let lines = served.stdout.split(separator: 0x0A)
        let messages = try lines.map { try #require(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
        #expect(messages.compactMap { $0["id"] as? Int } == [1, 2, 3])

        let call = try #require(messages.first { $0["id"] as? Int == 3 }?["result"] as? [String: Any])
        #expect(call["isError"] as? Bool == false)
        let results = try #require((call["structuredContent"] as? [String: Any])?["results"] as? [[String: Any]])
        #expect((results.first?["path"] as? String)?.hasSuffix("Desktop/IMG_2031.jpg") == true)

        let log = String(decoding: served.stderr, as: UTF8.self)
        #expect(log.contains("related: "), "the log has counts and timings")
        #expect(!log.contains("wifi") && !log.contains("trout-meadow"), "never the question or a result")
    }
}
