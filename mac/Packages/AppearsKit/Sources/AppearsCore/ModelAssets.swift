import CryptoKit
import Foundation

/// A small, signed-in-the-app description of the exact model files we accept.
/// No remotely supplied manifest can choose URLs, paths or checksums.
public struct ModelDescriptor: Codable, Sendable, Equatable {
    public struct File: Codable, Sendable, Equatable {
        public let name: String
        public let size: Int64
        public let sha256: String
        public init(name: String, size: Int64, sha256: String) {
            self.name = name; self.size = size; self.sha256 = sha256
        }
    }
    public let id: String
    public let baseURL: URL
    public let files: [File]
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    public init(id: String, baseURL: URL, files: [File]) {
        self.id = id; self.baseURL = baseURL; self.files = files
    }
    public static func bundled() throws -> Self {
        let url = Bundle.module.url(forResource: "model-download", withExtension: "json")!
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    public func validate() throws {
        guard !files.isEmpty, id.range(of: "^[a-zA-Z0-9-]+$", options: .regularExpression) != nil,
              baseURL.absoluteString == "https://appea.rs/models/\(id)/",
              Set(files.map(\.name)).count == files.count,
              files.allSatisfy({ file in
                  file.name.range(of: "^[a-zA-Z0-9_-]+\\.[a-zA-Z0-9]+$", options: .regularExpression) != nil && file.size > 0 &&
                  file.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
              }) else { throw ModelAssetError.invalidDescriptor }
    }
}

public enum ModelAssetError: LocalizedError {
    case invalidDescriptor, missing, checksum(String)
    public var errorDescription: String? {
        switch self {
        case .invalidDescriptor: "The model download information isn't valid."
        case .missing: "The on-device model is still downloading."
        case .checksum(let file): "The download of \(file) didn't pass its integrity check. Please retry."
        }
    }
}

public enum ModelAssets {
    public static let downloaderID = "rs.appea.appears.downloader"
    /// The downloader can write only its sandbox container. The engine's existing
    /// read-only home exception lets it read the finished model there.
    public static var root: URL {
        URL(filePath: FileScanner.realHome).appending(path: "Library/Containers/\(downloaderID)/Data/Library/Application Support/Appears/Models")
    }
    public static func folder(for descriptor: ModelDescriptor, root: URL = root) -> URL { root.appending(path: descriptor.id) }
    public static func checksum(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 2 << 20), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func matches(_ file: ModelDescriptor.File, at url: URL) -> Bool {
        guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(file.size) else { return false }
        return (try? checksum(url)) == file.sha256
    }
    /// The marker is written only after every checksum passes. Check sizes on
    /// subsequent launches so loading an installed model doesn't hash 900 MB again.
    public static func isInstalled(_ descriptor: ModelDescriptor, root: URL = root) -> Bool {
        let folder = folder(for: descriptor, root: root)
        guard let marker = try? Data(contentsOf: folder.appending(path: "verified.json")),
              let installed = try? JSONDecoder().decode(ModelDescriptor.self, from: marker), installed == descriptor else { return false }
        return descriptor.files.allSatisfy { (try? folder.appending(path: $0.name).resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int($0.size) }
    }
}

public struct ModelDownloadStatus: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case waiting, downloading, verifying, ready, failed }
    public var phase: Phase = .waiting
    public var received: Int64 = 0
    public var total: Int64 = 0
    public var error: String?
    public var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
    public init(phase: Phase = .waiting, received: Int64 = 0, total: Int64 = 0, error: String? = nil) {
        self.phase = phase; self.received = received; self.total = total; self.error = error
    }
}

/// No payload: the helper cannot be asked to upload data, fetch arbitrary URLs,
/// or inspect a path. It only downloads the model pinned inside its signed bundle.
@objc public protocol ModelDownloadXPC {
    func status(reply: @escaping @Sendable (Data) -> Void)
    func start(reply: @escaping @Sendable (Data) -> Void)
    func retry(reply: @escaping @Sendable (Data) -> Void)
}
