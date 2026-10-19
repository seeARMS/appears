import AppearsCore
import Foundation
import Testing

@testable import Lightning

/// The decision model: `APPEARS_DECIDER`, else `mac/Models/h2o-lightning-4b-q4` above this file
/// (made by `mac/scripts/prepare_decider.py`).
enum DeciderFolder {
    static let url: URL = {
        if let path = ProcessInfo.processInfo.environment["APPEARS_DECIDER"] { return URL(filePath: path) }
        var url = URL(filePath: #filePath)
        while url.path != "/" {
            url.deleteLastPathComponent()
            let candidate = url.appending(path: "mac/Models/h2o-lightning-4b-q4")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return URL(filePath: "mac/Models/h2o-lightning-4b-q4")
    }()

    static var exists: Bool { LightningDecider.isUsable(url) }
}

/// Decisions from mlx-vlm with the same weights, written by `mac/scripts/reference_decisions.py`.
struct ReferenceDecisions: Decodable {
    struct Case: Decodable {
        struct Option: Decodable { let name: String; let description: String }
        let record: String
        let question: String
        let options: [Option]
        let prompt: String
        let ids: [Int]
        let probabilities: [Double]

        var request: DecisionRequest {
            DecisionRequest(record: record, question: question,
                            options: options.map { DecisionOption(name: $0.name, description: $0.description) })
        }
    }
    let labels: [Int]
    let cases: [Case]

    static func load() throws -> Self {
        let url = try #require(Bundle.module.url(forResource: "reference-decisions", withExtension: "json"))
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

@Test func promptMatchesTheShim() throws {
    for reference in try ReferenceDecisions.load().cases {
        #expect(try DecisionPrompt.render(reference.request) == reference.prompt)
    }
}

@Test(.enabled(if: DeciderFolder.exists)) func tokensMatchTheReference() async throws {
    let decider = LightningDecider(folder: DeciderFolder.url)
    for reference in try ReferenceDecisions.load().cases {
        #expect(try await decider.tokens(DecisionPrompt.render(reference.request)) == reference.ids)
    }
}

/// The 4-bit weights are the same on both sides; what differs is kernel arithmetic, so answers
/// must agree and probabilities stay close.
@Test(.enabled(if: DeciderFolder.exists)) func decisionsMatchTheReference() async throws {
    let decider = LightningDecider(folder: DeciderFolder.url)
    for reference in try ReferenceDecisions.load().cases {
        let probabilities = try await decider.decide(reference.request)
        #expect(probabilities.count == reference.probabilities.count)
        let gap = zip(probabilities, reference.probabilities).map { abs($0 - $1) }.max() ?? 1
        #expect(gap < 0.03, "\(reference.question): \(probabilities) vs \(reference.probabilities)")
        if let top = reference.probabilities.max(), reference.probabilities.filter({ $0 > top - 0.05 }).count == 1 {
            #expect(probabilities.firstIndex(of: probabilities.max()!) == reference.probabilities.firstIndex(of: top))
        }
    }
}

@Test func theModelIDNamesTheWeightsAndThePrompt() {
    #expect(DecisionPrompt.fingerprint.count == 8 && DecisionPrompt.fingerprint.allSatisfy(\.isHexDigit))
    let decider = LightningDecider(folder: URL(filePath: "/models/h2o-lightning-4b-acaf0d4e-q4"))
    #expect(decider.modelID == "h2o-lightning-4b@h2o-lightning-4b-acaf0d4e-q4/" + DecisionPrompt.fingerprint)
}

@Test func probabilitiesUseTheShimTemperature() throws {
    let p = try DecisionPrompt.probabilities([0, log(2) * 0.75])
    #expect(abs(p[0] - 1.0 / 3) < 1e-9 && abs(p[1] - 2.0 / 3) < 1e-9)
    #expect(throws: DecisionError.self) { try DecisionPrompt.probabilities([.nan, 0]) }
}

@Test(.enabled(if: DeciderFolder.exists)) func aRejectedPromptStillReleasesTheModel() async throws {
    // The prompt is valid but too long, so it's rejected after the model has loaded.
    let decider = LightningDecider(folder: DeciderFolder.url, idleUnload: .milliseconds(500))
    let long = DecisionRequest(record: String(repeating: "word ", count: LightningDecider.maximumTokens + 100), question: "Which one?",
                               options: [DecisionOption(name: "one", description: "the first"), DecisionOption(name: "two", description: "the second")])
    await #expect(throws: DecisionError.self) { try await decider.decide(long) }
    #expect(await decider.isLoaded)
    try await Task.sleep(for: .seconds(2))
    #expect(await !decider.isLoaded)
}
