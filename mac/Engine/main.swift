import AppearsCore
import AppearsMessages
import Foundation
import GemmaEmbedder
import Lightning

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
    private var lastDeciderCheck = ContinuousClock.now - .seconds(60)

    /// The app's data lives in this service's container.
    static var dataFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Appears")
    }

    func get() async throws -> Engine {
        if let engine {
            attachDecider(to: engine)
            return engine
        }
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
                                    messagesURL: settings.homeOverride == nil ? ChatDatabase.defaultURL : nil,
                                    decider: Self.installedDecider())
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

    /// The decision model, when its verified files are installed. It loads its weights on its
    /// first decision and releases them when idle.
    static func installedDecider() -> (any Decider)? {
        guard let descriptor = try? ModelDescriptor.bundledDecider(), ModelAssets.isInstalled(descriptor) else { return nil }
        let folder = ModelAssets.folder(for: descriptor)
        return LightningDecider.isUsable(folder) ? LightningDecider(folder: folder) : nil
    }

    /// The decision model usually finishes downloading after the engine has started; look
    /// for it at most once a minute until it's there.
    private func attachDecider(to engine: Engine) {
        guard !engine.hasDecider, ContinuousClock.now - lastDeciderCheck >= .seconds(60) else { return }
        lastDeciderCheck = .now
        if let decider = Self.installedDecider() { engine.setDecider(decider) }
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
