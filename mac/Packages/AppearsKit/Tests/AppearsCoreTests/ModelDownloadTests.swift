import AppearsCore
import Foundation
import Testing
@testable import AppearsDownloads

@Suite struct ModelDownloadTests {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    private func descriptor(_ root: URL, text: String = "made-up weights") throws -> ModelDescriptor {
        let source = root.appending(path: "fixture")
        try text.write(to: source, atomically: true, encoding: .utf8)
        return ModelDescriptor(id: "test-model", baseURL: URL(string: "https://appea.rs/models/test-model/")!, files: [
            .init(name: "model.safetensors", size: Int64(text.utf8.count), sha256: try ModelAssets.checksum(source))
        ])
    }
    private func finished(_ installer: ModelInstaller) async throws -> ModelDownloadStatus {
        for _ in 0..<200 {
            let state = await installer.status()
            if state.phase == .ready || state.phase == .failed { return state }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Download test timed out"])
    }

    @Test func bundledPinsAndPathValidation() throws {
        let descriptor = try ModelDescriptor.bundled()
        try descriptor.validate()
        #expect(descriptor.files.count == 10)
        #expect(descriptor.totalBytes > 800_000_000)
        let bad = ModelDescriptor(id: "escape", baseURL: URL(string: "https://other.example/models/escape/")!, files: descriptor.files)
        #expect(throws: (any Error).self) { try bad.validate() }
        let traversal = ModelDescriptor(id: "test", baseURL: URL(string: "https://appea.rs/models/test/")!, files: [.init(name: "../private.json", size: 1, sha256: String(repeating: "a", count: 64))])
        #expect(throws: (any Error).self) { try traversal.validate() }
    }

    @Test func verifiesBeforeActivationAndReusesInstalledModelOffline() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = try descriptor(root)
        let installer = ModelInstaller(descriptor: descriptor, root: root) { url, resume, progress in
            #expect(url.absoluteString == "https://appea.rs/models/test-model/model.safetensors")
            #expect(resume == nil)
            let copy = root.appending(path: UUID().uuidString)
            try FileManager.default.copyItem(at: root.appending(path: "fixture"), to: copy)
            progress(descriptor.totalBytes)
            return (copy, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(!ModelAssets.isInstalled(descriptor, root: root))
        await installer.start()
        #expect(try await finished(installer).phase == .ready)
        #expect(ModelAssets.isInstalled(descriptor, root: root))
        let offline = ModelInstaller(descriptor: descriptor, root: root) { _, _, _ in
            Issue.record("An installed model must not download again")
            throw URLError(.notConnectedToInternet)
        }
        await offline.start()
        #expect(try await finished(offline).phase == .ready)
    }

    @Test func corruptDownloadNeverBecomesReady() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = try descriptor(root)
        let installer = ModelInstaller(descriptor: descriptor, root: root) { url, _, _ in
            let corrupt = root.appending(path: UUID().uuidString)
            try String(repeating: "x", count: Int(descriptor.files[0].size)).write(to: corrupt, atomically: true, encoding: .utf8)
            return (corrupt, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await installer.start()
        let state = try await finished(installer)
        #expect(state.phase == .failed)
        #expect(state.error?.contains("integrity") == true)
        #expect(!ModelAssets.isInstalled(descriptor, root: root))
    }

    @Test func failedDownloadRetainsResumeDataAndRetryCompletes() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = try descriptor(root)
        let transport = RetryTransport(root: root)
        let installer = ModelInstaller(descriptor: descriptor, root: root) { url, resume, _ in
            try await transport.fetch(url, resume: resume)
        }
        await installer.start()
        #expect(try await finished(installer).phase == .failed)
        #expect(!ModelAssets.isInstalled(descriptor, root: root))
        await installer.start(retry: true)
        #expect(try await finished(installer).phase == .ready)
        #expect(await transport.usedResume)
    }
}

private actor RetryTransport {
    let root: URL
    var first = true
    var usedResume = false
    init(root: URL) { self.root = root }
    func fetch(_ url: URL, resume: Data?) throws -> (URL, URLResponse) {
        if first {
            first = false
            throw NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, userInfo: [NSURLSessionDownloadTaskResumeData: Data("resume token".utf8)])
        }
        usedResume = resume == Data("resume token".utf8)
        let copy = root.appending(path: UUID().uuidString)
        try FileManager.default.copyItem(at: root.appending(path: "fixture"), to: copy)
        return (copy, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
