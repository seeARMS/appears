import AppearsCore
import Foundation

/// Talks to AppearsEngine.xpc. Every call is JSON over one generic XPC method.
final class EngineClient: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private let makeConnection: @Sendable () -> NSXPCConnection

    init(makeConnection: @escaping @Sendable () -> NSXPCConnection = {
        NSXPCConnection(serviceName: "rs.appea.appears.engine")
    }) {
        self.makeConnection = makeConnection
    }

    struct EngineError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func proxy(_ errorHandler: @escaping @Sendable (Error) -> Void) -> EngineXPC? {
        lock.lock()
        defer { lock.unlock() }
        if connection == nil {
            let connection = makeConnection()
            connection.remoteObjectInterface = NSXPCInterface(with: EngineXPC.self)
            connection.invalidationHandler = { [weak self] in
                self?.lock.withLock { self?.connection = nil }
            }
            connection.resume()
            self.connection = connection
        }
        return connection?.remoteObjectProxyWithErrorHandler(errorHandler) as? EngineXPC
    }

    func call<Response: Decodable>(_ method: EngineMethod, _ payload: some Encodable, as: Response.Type) async throws -> Response {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(payload)
        let pending = XPCReply()
        let reply: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard pending.install(continuation) else { return }
                guard let proxy = proxy({ pending.finish(.failure($0)) }) else {
                    pending.finish(.failure(EngineError(message: "Couldn't reach the engine")))
                    return
                }
                proxy.call(method.rawValue, payload: data) { data, error in
                    if let data { pending.finish(.success(data)) } else {
                        pending.finish(.failure(EngineError(message: error ?? "The engine didn't answer")))
                    }
                }
            }
        } onCancel: {
            pending.finish(.failure(CancellationError()))
        }
        try Task.checkCancellation()
        return try JSONDecoder().decode(Response.self, from: reply)
    }

    struct Empty: Codable {}

    func send(_ method: EngineMethod, _ payload: some Encodable = Empty()) async {
        _ = try? await call(method, payload, as: Empty.self)
    }

    func status() async -> EngineStatus? { try? await call(.status, Empty(), as: EngineStatus.self) }

    func related(_ request: RecallRequest) async throws -> RecallResponse {
        try await call(.related, request, as: RecallResponse.self)
    }

    func search(_ request: SearchRequest) async throws -> RecallResponse {
        try await withTaskCancellationHandler {
            try await call(.search, request, as: RecallResponse.self)
        } onCancel: {
            guard let token = request.token else { return }
            // This control request is independent of the cancelled UI task. It must
            // reach the engine even when the original reply has not returned yet.
            Task { await self.send(.cancelSearch, token) }
        }
    }

    func log(_ entry: JournalEntry) async -> Int64? { try? await call(.log, entry, as: Int64.self) }

    func stats(days: Int) async -> JournalStats? { try? await call(.stats, days, as: JournalStats.self) }
}

/// Cancellation can race installation, the XPC reply, and its error handler.
/// Resolve once, resuming outside the lock, including cancel-before-install.
final class XPCReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var result: Result<Data, any Error>?

    func install(_ continuation: CheckedContinuation<Data, any Error>) -> Bool {
        let result: Result<Data, any Error>? = lock.withLock {
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let result { continuation.resume(with: result); return false }
        return true
    }

    func finish(_ result: Result<Data, any Error>) {
        let continuation = lock.withLock {
            guard self.result == nil else { return nil as CheckedContinuation<Data, any Error>? }
            self.result = result
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}

/// The model downloader also uses a reply-once guard and has no search cancellation.
final class XPCReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
