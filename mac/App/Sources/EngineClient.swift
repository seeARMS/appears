import AppearsCore
import Foundation

/// Talks to AppearsEngine.xpc. Every call is JSON over one generic XPC method.
final class EngineClient: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    struct EngineError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func proxy(_ errorHandler: @escaping @Sendable (Error) -> Void) -> EngineXPC? {
        lock.lock()
        defer { lock.unlock() }
        if connection == nil {
            let connection = NSXPCConnection(serviceName: "rs.appea.appears.engine")
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
        let data = try JSONEncoder().encode(payload)
        let reply: Data = try await withCheckedThrowingContinuation { continuation in
            let once = XPCReplyOnce()
            guard let proxy = proxy({ error in once.run { continuation.resume(throwing: error) } }) else {
                continuation.resume(throwing: EngineError(message: "Couldn't reach the engine"))
                return
            }
            proxy.call(method.rawValue, payload: data) { data, error in
                once.run {
                    if let data { continuation.resume(returning: data) } else {
                        continuation.resume(throwing: EngineError(message: error ?? "The engine didn't answer"))
                    }
                }
            }
        }
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

    func search(_ text: String) async throws -> RecallResponse {
        try await call(.search, SearchRequest(text: text), as: RecallResponse.self)
    }

    func log(_ entry: JournalEntry) async -> Int64? { try? await call(.log, entry, as: Int64.self) }

    func stats(days: Int) async -> JournalStats? { try? await call(.stats, days, as: JournalStats.self) }
}

/// Resumes a continuation at most once (XPC can call both the reply and the error handler).
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
