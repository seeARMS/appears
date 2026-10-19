import AppearsCore
import Foundation

/// Runs only in AppearsDownloader.xpc, whose sandbox has network.client and no
/// user-file access. Keeps completed files and URLSession resume data on disk.
public actor ModelInstaller {
    typealias Fetch = @Sendable (URL, Data?, @Sendable (Int64) -> Void) async throws -> (URL, URLResponse)
    private let descriptor: ModelDescriptor
    private let root: URL
    /// How errors name this download.
    private let name: String
    private var current: ModelDownloadStatus
    private var task: Task<Void, Never>?
    private let fetchOverride: Fetch?

    public init(descriptor: ModelDescriptor, root: URL = ModelAssets.root, name: String = "the on-device model") {
        self.descriptor = descriptor; self.root = root; self.name = name
        fetchOverride = nil
        current = ModelDownloadStatus(total: descriptor.totalBytes)
    }
    /// Test transport; production always uses the restricted URLSession below.
    init(descriptor: ModelDescriptor, root: URL, name: String = "the on-device model", fetch: @escaping Fetch) {
        self.descriptor = descriptor; self.root = root; self.name = name; fetchOverride = fetch
        current = ModelDownloadStatus(total: descriptor.totalBytes)
    }

    public func status() -> ModelDownloadStatus { current }
    /// Waits for a running install to end, then reports how it ended.
    public func finished() async -> ModelDownloadStatus {
        await task?.value
        return current
    }
    @discardableResult public func start(retry: Bool = false) -> ModelDownloadStatus {
        guard task == nil, current.phase != .ready, current.phase != .failed || retry else { return current }
        current.error = nil
        current.phase = .verifying
        task = Task { await install() }
        return current
    }

    private func progress(_ bytes: Int64) {
        guard current.phase != .ready, current.phase != .failed else { return }
        current.received = min(descriptor.totalBytes, bytes)
    }

    private func install() async {
        defer { task = nil }
        do {
            try descriptor.validate()
            if ModelAssets.isInstalled(descriptor, root: root) {
                current = ModelDownloadStatus(phase: .ready, received: descriptor.totalBytes, total: descriptor.totalBytes)
                return
            }
            let fm = FileManager.default
            let staging = root.appending(path: ".\(descriptor.id)-partial")
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var modelRoot = root
            try modelRoot.setResourceValues(values)
            var done: Int64 = 0
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            config.urlCache = nil
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 24 * 60 * 60
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            for file in descriptor.files {
                let destination = staging.appending(path: file.name)
                current.phase = .verifying
                if ModelAssets.matches(file, at: destination) { done += file.size; progress(done); continue }
                let resumeFile = staging.appending(path: file.name + ".resume")
                let base = done
                let onProgress: @Sendable (Int64) -> Void = { [weak self] bytes in Task { await self?.progress(base + bytes) } }
                let observer = DownloadProgress(update: onProgress)
                current.phase = .downloading
                let result: (URL, URLResponse)
                do {
                    let resume = try? Data(contentsOf: resumeFile)
                    try? fm.removeItem(at: resumeFile)
                    if let fetchOverride {
                        result = try await fetchOverride(descriptor.baseURL.appending(path: file.name), resume, onProgress)
                    } else if let resume {
                        // An invalid or stale resume token is discarded on failure;
                        // the next Retry starts this file again.
                        result = try await session.download(resumeFrom: resume, delegate: observer)
                    } else {
                        var request = URLRequest(url: descriptor.baseURL.appending(path: file.name))
                        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                        result = try await session.download(for: request, delegate: observer)
                    }
                } catch {
                    if let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                        try? resume.write(to: resumeFile, options: .atomic)
                    }
                    throw error
                }
                guard let response = result.1 as? HTTPURLResponse, [200, 206].contains(response.statusCode) else {
                    try? fm.removeItem(at: result.0)
                    throw NSError(domain: "AppearsModelDownload", code: 1, userInfo: [NSLocalizedDescriptionKey: "The model download isn't available right now. Check your connection and retry."])
                }
                try? fm.removeItem(at: destination)
                try fm.moveItem(at: result.0, to: destination)
                current.phase = .verifying
                guard ModelAssets.matches(file, at: destination) else {
                    try? fm.removeItem(at: destination)
                    throw ModelAssetError.checksum(file.name)
                }
                try? fm.removeItem(at: resumeFile)
                done += file.size
                progress(done)
            }
            try JSONEncoder().encode(descriptor).write(to: staging.appending(path: "verified.json"), options: .atomic)
            let installed = ModelAssets.folder(for: descriptor, root: root)
            if fm.fileExists(atPath: installed.path) { try fm.removeItem(at: installed) }
            try fm.moveItem(at: staging, to: installed)
            current = ModelDownloadStatus(phase: .ready, received: descriptor.totalBytes, total: descriptor.totalBytes)
        } catch {
            current.phase = .failed
            current.error = "Couldn't finish downloading \(name). \(error.localizedDescription)"
        }
    }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let update: @Sendable (Int64) -> Void
    init(update: @escaping @Sendable (Int64) -> Void) { self.update = update }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        update(totalBytesWritten)
    }
    // Pinned immutable model URLs are served directly. Refuse every redirect so
    // the server cannot choose a new destination for the helper.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
