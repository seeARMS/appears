import Foundation
@testable import AppearsCore

/// A stand-in decision model: answers from a rule instead of weights, and remembers what it
/// was asked.
final class ScriptedDecider: Decider, @unchecked Sendable {
    let modelID = "scripted"
    private let choose: @Sendable (DecisionRequest) -> [Double]
    private let lock = NSLock()
    private var asked: [DecisionRequest] = []

    init(_ choose: @escaping @Sendable (DecisionRequest) -> [Double]) {
        self.choose = choose
    }

    /// `probability` on the first option whose text contains `text`; the rest on "none".
    static func picking(_ text: String, probability: Double = 0.9) -> ScriptedDecider {
        ScriptedDecider { request in
            var result = Array(repeating: 0.0, count: request.options.count)
            if let index = request.options.dropLast().firstIndex(where: { $0.description.contains(text) }) {
                result[index] = probability
                result[result.count - 1] = 1 - probability
            } else {
                result[result.count - 1] = 1
            }
            return result
        }
    }

    var requests: [DecisionRequest] { lock.withLock { asked } }

    func decide(_ request: DecisionRequest) async throws -> [Double] {
        lock.withLock { asked.append(request) }
        return choose(request)
    }
}

struct FailingDecider: Decider {
    let modelID = "failing"
    func decide(_ request: DecisionRequest) async throws -> [Double] { throw DecisionError.invalid("test") }
}
