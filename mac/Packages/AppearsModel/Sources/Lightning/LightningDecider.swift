import AppearsCore
import Foundation
import Hub
import MLX
import Tokenizers

/// H2O-Lightning-4B (Apache-2.0, on Qwen3.5-4B) as Appears' decision model. One forward pass
/// per decision; the answer is read from the tied output head's rows for the option labels,
/// in float32, as the model's config asks. Loaded on first use and released when idle, so a
/// Mac with little memory only holds it while it's deciding.
public actor LightningDecider: Decider {
    public nonisolated let modelID: String
    private let folder: URL
    private let idleUnload: Duration
    private var loaded: Loaded?
    private var lastUse = ContinuousClock.now
    private var unloadTask: Task<Void, Never>?

    /// Longer prompts are rejected rather than truncated: callers bound what they send.
    static let maximumTokens = 8_192

    struct Loaded {
        let model: Qwen35Model
        let tokenizer: any Tokenizer
        let specials: [(text: String, id: Int)]
        let labelIDs: [Int]
    }

    public init(folder: URL, idleUnload: Duration = .seconds(300)) {
        self.folder = folder
        self.idleUnload = idleUnload
        modelID = "h2o-lightning-4b@\(folder.lastPathComponent)/" + DecisionPrompt.prefill
    }

    /// Whether `folder` holds what this decider needs, without loading it.
    public static func isUsable(_ folder: URL) -> Bool {
        ["config.json", "tokenizer.json", "tokenizer_config.json"].allSatisfy {
            FileManager.default.fileExists(atPath: folder.appending(path: $0).path)
        } && ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).contains {
            $0.hasPrefix("model") && $0.hasSuffix(".safetensors")
        }
    }

    public func decide(_ request: DecisionRequest) async throws -> [Double] {
        try Task.checkCancellation()
        let prompt = try DecisionPrompt.render(request)
        let state = try await load()
        let ids = encode(prompt, state)
        guard ids.count <= Self.maximumTokens else { throw DecisionError.invalid("prompt too long (\(ids.count) tokens)") }
        try Task.checkCancellation()
        let labels = Array(state.labelIDs.prefix(request.options.count))
        let hidden = state.model.lastHidden(ids.map(Int32.init)).asType(.float32)
        let rows = state.model.embeddings.rows(MLXArray(labels.map(Int32.init))).asType(.float32)
        let logits = matmul(rows, hidden)
        eval(logits)
        lastUse = .now
        scheduleUnload()
        return try DecisionPrompt.probabilities(logits.asArray(Float.self).map(Double.init))
    }

    /// A rendered prompt's token ids, for tests.
    func tokens(_ prompt: String) async throws -> [Int] { encode(prompt, try await load()) }

    /// The token ids for a rendered prompt. Special tokens are split out first, as Hugging Face
    /// tokenizers do, then each stretch of text is encoded without adding any.
    func encode(_ text: String, _ state: Loaded) -> [Int] {
        var ids: [Int] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            let next = state.specials.compactMap { special in rest.range(of: special.text).map { ($0, special) } }
                .min { $0.0.lowerBound < $1.0.lowerBound }
            guard let (range, special) = next else {
                ids += state.tokenizer.encode(text: String(rest), addSpecialTokens: false)
                break
            }
            if range.lowerBound > rest.startIndex {
                ids += state.tokenizer.encode(text: String(rest[..<range.lowerBound]), addSpecialTokens: false)
            }
            ids.append(special.id)
            rest = rest[range.upperBound...]
        }
        return ids
    }

    private func load() async throws -> Loaded {
        if let loaded { return loaded }
        let model = try Qwen35Model(folder: folder)
        // swift-transformers doesn't know the class name "Qwen3_5Tokenizer"; it's Qwen2's
        // byte-level BPE, and the tests check every token against the Python tokenizer.
        func config(_ name: String, override: [String: Any] = [:]) throws -> Config {
            guard var object = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: name))) as? [String: Any] else {
                throw DecisionError.invalid("unreadable \(name)")
            }
            object.merge(override) { $1 }
            return Config(Dictionary(uniqueKeysWithValues: object.map { ($0.key as NSString, $0.value) }))
        }
        let tokenizer = try AutoTokenizer.from(
            tokenizerConfig: config("tokenizer_config.json", override: ["tokenizer_class": "Qwen2Tokenizer"]),
            tokenizerData: config("tokenizer.json"))
        struct Added: Decodable { let content: String; let id: Int }
        struct File: Decodable { let added_tokens: [Added] }
        let added = try JSONDecoder().decode(File.self, from: Data(contentsOf: folder.appending(path: "tokenizer.json"))).added_tokens
        // Longest first, so one special token can't hide a longer one that starts the same way.
        let specials = added.map { ($0.content, $0.id) }.sorted { $0.0.count > $1.0.count }
        let state = Loaded(model: model, tokenizer: tokenizer, specials: specials, labelIDs: [])
        // Each label must be exactly one token after the prefill and a space (the shim's check).
        let prefix = encode(DecisionPrompt.prefill, state)
        let labelIDs = try DecisionPrompt.labels.map { label -> Int in
            let ids = encode(DecisionPrompt.prefill + " " + label, state)
            guard ids.count == prefix.count + 1, Array(ids.prefix(prefix.count)) == prefix else {
                throw DecisionError.invalid("label \(label) isn't one token")
            }
            return ids[ids.count - 1]
        }
        guard Set(labelIDs).count == labelIDs.count, labelIDs.allSatisfy({ $0 < model.configuration.vocabularySize }) else {
            throw DecisionError.invalid("labels aren't distinct tokens")
        }
        let result = Loaded(model: model, tokenizer: tokenizer, specials: specials, labelIDs: labelIDs)
        loaded = result
        return result
    }

    private func scheduleUnload() {
        unloadTask?.cancel()
        let wait = idleUnload
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle()
        }
    }

    private func unloadIfIdle() {
        guard ContinuousClock.now - lastUse >= idleUnload else { return }
        loaded = nil
        MLX.GPU.clearCache()
    }
}
