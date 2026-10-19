import Foundation

/// One option a decision model can choose: a short name and the text it reads.
public struct DecisionOption: Sendable, Equatable {
    public var name: String
    public var description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

/// A record (what the person is doing), a question about it, and the complete set of answers.
/// The record holds screen context: it lives in memory only and is never logged or stored.
public struct DecisionRequest: Sendable, Equatable {
    public var record: String
    public var question: String
    public var options: [DecisionOption]

    public init(record: String, question: String, options: [DecisionOption]) {
        self.record = record
        self.question = question
        self.options = options
    }
}

/// Reads a record and a question together and returns a probability for every option. This is
/// what decides which result answers, and how sure Appears is: one calibrated number.
public protocol Decider: Sendable {
    /// Changes when the weights or the prompt change, so stored outcomes can be told apart.
    var modelID: String { get }
    /// Probabilities aligned with `request.options`, summing to 1.
    func decide(_ request: DecisionRequest) async throws -> [Double]
}

public enum DecisionError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let reason): "The decision model couldn't answer: \(reason)" }
    }
}

/// H2O-Lightning-4B's prompt and readout, exactly as its shim (`h2o_lightning_shim.py` at
/// v1.2.3, with `serve_config.json`) renders them for a choice question. The model was trained
/// on this layout, so changing any string here changes its answers.
public enum DecisionPrompt {
    public static let system = "You are a decision engine. You read a record and answer one question about it by choosing exactly one option. Reply with a single letter."
    public static let prefill = "Answer:"
    /// The shim's choice temperature.
    public static let temperature = 0.75
    /// The model decides best with up to about 16 options (its model card).
    public static let maximumOptions = 16
    /// The first labels of the shim's 255; each is one token after the prefill and a space.
    public static let labels = (UnicodeScalar("A").value...UnicodeScalar("Z").value).map { String(UnicodeScalar($0)!) }

    /// The user turn: the record, the question, then one `A) name: description` line per option.
    public static func user(_ request: DecisionRequest) throws -> String {
        guard request.options.count >= 2, request.options.count <= labels.count else {
            throw DecisionError.invalid("\(request.options.count) options")
        }
        let lines = zip(labels, request.options).map { "\($0)) \($1.name): \($1.description)" }
        return "record: \(request.record)\nquestion: \(request.question)\noptions:\n" + lines.joined(separator: "\n")
    }

    /// The whole prompt in Qwen3.5's chat template with thinking off, ending with the prefill.
    /// Special tokens appear literally; a tokenizer must split on them before encoding.
    public static func render(_ request: DecisionRequest) throws -> String {
        "<|im_start|>system\n" + system.trimmingCharacters(in: .whitespacesAndNewlines) + "<|im_end|>\n"
            + "<|im_start|>user\n" + (try user(request)).trimmingCharacters(in: .whitespacesAndNewlines) + "<|im_end|>\n"
            + "<|im_start|>assistant\n<think>\n\n</think>\n\n" + prefill
    }

    /// softmax(logits / T) over the options. Log-probabilities give the same result, since
    /// their shared normalizer cancels.
    public static func probabilities(_ logits: [Double], temperature: Double = temperature) throws -> [Double] {
        guard !logits.isEmpty, logits.allSatisfy(\.isFinite) else { throw DecisionError.invalid("non-finite scores") }
        let scaled = logits.map { $0 / max(temperature, 1e-3) }
        let top = scaled.max()!
        let exps = scaled.map { exp($0 - top) }
        let sum = exps.reduce(0, +)
        guard sum.isFinite, sum > 0 else { throw DecisionError.invalid("scores can't be normalized") }
        return exps.map { $0 / sum }
    }
}
