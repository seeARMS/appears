import Foundation

/// Revisions are monotonic within the app's search session, including clear/close.
/// Keeping the latest revision handles cancellation arriving before its XPC request.
public struct SearchToken: Sendable, Codable, Equatable {
    public let session: UUID
    public let revision: UInt64

    public init(session: UUID, revision: UInt64) {
        self.session = session
        self.revision = revision
    }
}

actor SearchCoordinator {
    private struct Session {
        var revision: UInt64
        var task: Task<RecallResponse, any Error>?
    }
    private var sessions: [UUID: Session] = [:]

    func run(_ token: SearchToken, operation: @escaping @Sendable () async throws -> RecallResponse) async throws -> RecallResponse {
        if let previous = sessions[token.session] {
            guard token.revision > previous.revision else { throw CancellationError() }
            previous.task?.cancel()
        }
        let task = Task(priority: .userInitiated) {
            try Task.checkCancellation()
            let response = try await operation()
            try Task.checkCancellation()
            return response
        }
        sessions[token.session] = Session(revision: token.revision, task: task)
        defer {
            if sessions[token.session]?.revision == token.revision { sessions[token.session]?.task = nil }
        }
        let response = try await task.value
        guard sessions[token.session]?.revision == token.revision else { throw CancellationError() }
        return response
    }

    func cancel(_ token: SearchToken) {
        if let previous = sessions[token.session] {
            guard token.revision >= previous.revision else { return }
            previous.task?.cancel()
        }
        sessions[token.session] = Session(revision: token.revision, task: nil)
    }
}
