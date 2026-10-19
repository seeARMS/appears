import AppearsCore
import AppearsDownloads
import Foundation

/// Installs the two models pinned in this bundle: the embedder first (Appears needs it to
/// work at all), then the decision model. The interface still takes no payload: the app can
/// only ask for status, start and retry.
final class DownloadService: NSObject, ModelDownloadXPC {
    let embedder: ModelInstaller
    let decider: ModelInstaller

    init(embedder: ModelInstaller, decider: ModelInstaller) {
        self.embedder = embedder
        self.decider = decider
    }

    func status(reply: @escaping @Sendable (Data) -> Void) {
        Task { [embedder, decider] in reply(try! JSONEncoder().encode(await Self.combined(embedder, decider))) }
    }

    func start(reply: @escaping @Sendable (Data) -> Void) {
        Task { [embedder, decider] in
            await embedder.start()
            Self.chain(embedder, decider, retry: false)
            reply(try! JSONEncoder().encode(await Self.combined(embedder, decider)))
        }
    }

    func retry(reply: @escaping @Sendable (Data) -> Void) {
        Task { [embedder, decider] in
            await embedder.start(retry: true)
            Self.chain(embedder, decider, retry: true)
            reply(try! JSONEncoder().encode(await Self.combined(embedder, decider)))
        }
    }

    /// Starts the decision model once the embedder has finished, never alongside it.
    private static func chain(_ embedder: ModelInstaller, _ decider: ModelInstaller, retry: Bool) {
        Task {
            guard await embedder.finished().phase == .ready else { return }
            await decider.start(retry: retry)
        }
    }

    private static func combined(_ embedder: ModelInstaller, _ decider: ModelInstaller) async -> ModelDownloadStatus {
        var status = await embedder.status()
        status.answerModel = .init(await decider.status())
        return status
    }
}

final class DownloadListener: NSObject, NSXPCListenerDelegate {
    let service = DownloadService(
        embedder: ModelInstaller(descriptor: try! ModelDescriptor.bundled()),
        decider: ModelInstaller(descriptor: try! ModelDescriptor.bundledDecider(), name: "the answer model")
    )
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ModelDownloadXPC.self)
        connection.exportedObject = service
        connection.invalidationHandler = { exit(0) }
        connection.resume()
        return true
    }
}

xpc_transaction_begin()
let delegate = DownloadListener()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
