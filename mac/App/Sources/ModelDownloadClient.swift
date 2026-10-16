import AppearsCore
import Foundation

/// Talks to the restricted helper. This process never opens a network connection.
final class ModelDownloadClient: @unchecked Sendable {
    enum Action { case start, status, retry }
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    private func proxy(_ failure: @escaping @Sendable (Error) -> Void) -> ModelDownloadXPC? {
        lock.withLock {
            if connection == nil {
                let connection = NSXPCConnection(serviceName: ModelAssets.downloaderID)
                connection.remoteObjectInterface = NSXPCInterface(with: ModelDownloadXPC.self)
                connection.invalidationHandler = { [weak self] in self?.lock.withLock { self?.connection = nil } }
                connection.resume()
                self.connection = connection
            }
            return connection?.remoteObjectProxyWithErrorHandler(failure) as? ModelDownloadXPC
        }
    }

    func update(_ action: Action) async -> ModelDownloadStatus {
        do {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                let once = XPCReplyOnce()
                guard let service = proxy({ error in once.run { continuation.resume(throwing: error) } }) else {
                    once.run { continuation.resume(throwing: ModelAssetError.missing) }
                    return
                }
                let reply: @Sendable (Data) -> Void = { data in once.run { continuation.resume(returning: data) } }
                switch action {
                case .start: service.start(reply: reply)
                case .status: service.status(reply: reply)
                case .retry: service.retry(reply: reply)
                }
            }
            return try JSONDecoder().decode(ModelDownloadStatus.self, from: data)
        } catch {
            return ModelDownloadStatus(phase: .failed, error: "Couldn't reach the model downloader. Please retry.")
        }
    }
}
