import AppearsCore
import Foundation
import GemmaEmbedder

// AppearsEngine: the sandboxed XPC service that reads your files, runs the model, keeps the
// index and the journal, and answers the app. It has no network entitlement, so macOS blocks
// every connection it might try.

/// Loads the model and the engine once, on first use.
actor EngineHost {
    static let shared = EngineHost()
    private var engine: Engine?
    private var loading: Task<Engine, Error>?
    private var pendingSettings: SourceSettings?
    private var loadError: String?

    /// The app's data lives in this service's container.
    static var dataFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Appears")
    }

    func get() async throws -> Engine {
        if let engine { return engine }
        if let loading { return try await loading.value }
        let settings = pendingSettings ?? SourceSettings()
        let task = Task<Engine, Error> {
            let descriptor = try ModelDescriptor.bundled()
            guard ModelAssets.isInstalled(descriptor) else { throw ModelAssetError.missing }
            let folder = ModelAssets.folder(for: descriptor)
            let embedder = try await GemmaEmbedder.load(from: folder)
            // Demo mode keeps its own index, apart from your real one.
            let data = settings.homeOverride == nil ? Self.dataFolder : Self.dataFolder.deletingLastPathComponent().appending(path: "Appears-Demo")
            let engine = try Engine(folder: data, embedder: embedder, settings: settings,
                                    searchMessages: settings.homeOverride == nil ? MessagesReader() : nil)
            engine.start()
            return engine
        }
        loading = task
        defer { loading = nil } // A missing model on first launch must be retryable.
        do {
            let engine = try await task.value
            self.engine = engine
            loadError = nil
            return engine
        } catch {
            loadError = error.localizedDescription
            throw error
        }
    }

    /// Settings can arrive before the engine has loaded; keep them for the load.
    func remember(_ settings: SourceSettings) { pendingSettings = settings }
    var isLoaded: Bool { engine != nil }
    var startupStatus: EngineStatus {
        var status = EngineStatus()
        status.error = loadError
        return status
    }
}

final class EngineService: NSObject, EngineXPC {
    func call(_ method: String, payload: Data, reply: @escaping @Sendable (Data?, String?) -> Void) {
        guard let method = EngineMethod(rawValue: method) else {
            reply(nil, "Unknown method \(method)")
            return
        }
        Task {
            do {
                if method == .settings, let settings = try? JSONDecoder().decode(SourceSettings.self, from: payload) {
                    await EngineHost.shared.remember(settings)
                }
                // Status before the model has loaded: say so rather than wait for it.
                if method == .status, await !EngineHost.shared.isLoaded {
                    Task { _ = try? await EngineHost.shared.get() }
                    reply(try JSONEncoder().encode(await EngineHost.shared.startupStatus), nil)
                    return
                }
                let engine = try await EngineHost.shared.get()
                reply(try await engine.handle(method, payload: payload), nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: EngineXPC.self)
        connection.exportedObject = EngineService()
        // The app is the only client. When it quits, so does the engine.
        connection.invalidationHandler = { exit(0) }
        connection.resume()
        return true
    }
}

// Stay alive while the app is connected: indexing runs between requests.
xpc_transaction_begin()
let delegate = ListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
