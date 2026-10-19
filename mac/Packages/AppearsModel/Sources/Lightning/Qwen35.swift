import AppearsCore
import Foundation
import MLX

/// Qwen3.5's text model, as H2O-Lightning-4B uses it: one forward pass over a prompt, returning
/// the final normalized hidden state at its last position. No generation, no cache, no vision.
/// Ported from mlx-vlm's `qwen3_5/language.py` (Copyright © 2025 Prince Canuma, MIT License;
/// see ThirdParty/Lightning/NOTICE). Weights are an MLX 4-bit conversion.
struct Qwen35Configuration: Decodable {
    let hiddenSize: Int
    let layers: Int
    let heads: Int
    let kvHeads: Int
    let headDim: Int
    let vocabularySize: Int
    let fullAttentionInterval: Int
    let linearKeyHeads: Int
    let linearValueHeads: Int
    let linearKeyDim: Int
    let linearValueDim: Int
    let convolutionKernel: Int
    let epsilon: Float
    let rotaryDimensions: Int
    let ropeTheta: Float
    let groupSize: Int
    let bits: Int

    private struct File: Decodable {
        struct Text: Decodable {
            let hidden_size, num_hidden_layers, num_attention_heads, num_key_value_heads, head_dim, vocab_size: Int
            let full_attention_interval, linear_num_key_heads, linear_num_value_heads: Int
            let linear_key_head_dim, linear_value_head_dim, linear_conv_kernel_dim: Int
            let rms_norm_eps: Float
            let rope_parameters: Rope
        }
        struct Rope: Decodable { let partial_rotary_factor: Float; let rope_theta: Float }
        struct Quantization: Decodable { let group_size: Int; let bits: Int; let mode: String? }
        let text_config: Text
        let quantization: Quantization
    }

    init(contentsOf url: URL) throws {
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        let t = file.text_config
        hiddenSize = t.hidden_size; layers = t.num_hidden_layers; heads = t.num_attention_heads
        kvHeads = t.num_key_value_heads; headDim = t.head_dim; vocabularySize = t.vocab_size
        fullAttentionInterval = t.full_attention_interval
        linearKeyHeads = t.linear_num_key_heads; linearValueHeads = t.linear_num_value_heads
        linearKeyDim = t.linear_key_head_dim; linearValueDim = t.linear_value_head_dim
        convolutionKernel = t.linear_conv_kernel_dim; epsilon = t.rms_norm_eps
        rotaryDimensions = Int(Float(t.head_dim) * t.rope_parameters.partial_rotary_factor)
        ropeTheta = t.rope_parameters.rope_theta
        groupSize = file.quantization.group_size; bits = file.quantization.bits
        guard file.quantization.mode ?? "affine" == "affine", [4, 8].contains(bits), groupSize == 64,
              linearValueHeads % linearKeyHeads == 0, linearKeyDim == 128, linearValueDim % 4 == 0 else {
            throw DecisionError.invalid("unsupported model configuration")
        }
    }
}

/// A 4- or 8-bit affine-quantized matrix in MLX's packed layout.
struct QuantizedMatrix {
    let weight: MLXArray
    let scales: MLXArray
    let biases: MLXArray
    let groupSize: Int
    let bits: Int

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        quantizedMatmul(x, weight, scales: scales, biases: biases, transpose: true, groupSize: groupSize, bits: bits)
    }

    /// Selected rows, dequantized: token embeddings, or the tied output head's label rows.
    func rows(_ ids: MLXArray) -> MLXArray {
        dequantized(weight[ids], scales: scales[ids], biases: biases[ids], groupSize: groupSize, bits: bits)
    }
}

struct Qwen35Model {
    struct Attention {
        let q, k, v, o: QuantizedMatrix
        let qNorm, kNorm: MLXArray
    }

    struct LinearAttention {
        let qkv, z, b, a, out: QuantizedMatrix
        /// Depthwise causal convolution weights, [channels, kernel].
        let convolution: MLXArray
        let aLog, dtBias, norm: MLXArray
    }

    struct Layer {
        let inputNorm, postNorm: MLXArray
        let attention: Attention?
        let linear: LinearAttention?
        let gate, up, down: QuantizedMatrix
    }

    let configuration: Qwen35Configuration
    let embeddings: QuantizedMatrix
    let layers: [Layer]
    let norm: MLXArray

    /// Loads `model.safetensors` (or its shards). Vision tower weights, if present, are ignored.
    init(folder: URL) throws {
        let configuration = try Qwen35Configuration(contentsOf: folder.appending(path: "config.json"))
        self.configuration = configuration
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("model") && $0.pathExtension == "safetensors" }
        guard !files.isEmpty else { throw DecisionError.invalid("no weights") }
        var weights: [String: MLXArray] = [:]
        for file in files {
            for (key, value) in try loadArrays(url: file) {
                // A full checkpoint ("language_model.model.layers…") or a text-only one ("model.layers…").
                // The vision tower is never loaded.
                for prefix in ["language_model.model.", "model."] where key.hasPrefix(prefix) {
                    weights[String(key.dropFirst(prefix.count))] = value
                    break
                }
            }
        }
        func array(_ key: String) throws -> MLXArray {
            guard let value = weights[key] else { throw DecisionError.invalid("missing weight \(key)") }
            return value
        }
        func matrix(_ key: String) throws -> QuantizedMatrix {
            QuantizedMatrix(weight: try array(key + ".weight"), scales: try array(key + ".scales"),
                            biases: try array(key + ".biases"), groupSize: configuration.groupSize, bits: configuration.bits)
        }
        embeddings = try matrix("embed_tokens")
        norm = try array("norm.weight")
        layers = try (0..<configuration.layers).map { index in
            let p = "layers.\(index)."
            let linear = (index + 1) % configuration.fullAttentionInterval != 0
            return Layer(
                inputNorm: try array(p + "input_layernorm.weight"),
                postNorm: try array(p + "post_attention_layernorm.weight"),
                attention: linear ? nil : Attention(
                    q: try matrix(p + "self_attn.q_proj"), k: try matrix(p + "self_attn.k_proj"),
                    v: try matrix(p + "self_attn.v_proj"), o: try matrix(p + "self_attn.o_proj"),
                    qNorm: try array(p + "self_attn.q_norm.weight"), kNorm: try array(p + "self_attn.k_norm.weight")),
                linear: linear ? LinearAttention(
                    qkv: try matrix(p + "linear_attn.in_proj_qkv"), z: try matrix(p + "linear_attn.in_proj_z"),
                    b: try matrix(p + "linear_attn.in_proj_b"), a: try matrix(p + "linear_attn.in_proj_a"),
                    out: try matrix(p + "linear_attn.out_proj"),
                    convolution: try array(p + "linear_attn.conv1d.weight").squeezed(axis: -1),
                    aLog: try array(p + "linear_attn.A_log"), dtBias: try array(p + "linear_attn.dt_bias"),
                    norm: try array(p + "linear_attn.norm.weight")) : nil,
                gate: try matrix(p + "mlp.gate_proj"), up: try matrix(p + "mlp.up_proj"), down: try matrix(p + "mlp.down_proj"))
        }
        eval(weights.values.map { $0 })
    }

    /// The final normalized hidden state at the last position of `ids`.
    func lastHidden(_ ids: [Int32]) -> MLXArray {
        var h = embeddings.rows(MLXArray(ids)).expandedDimensions(axis: 0)  // [1, T, hidden]
        for layer in layers {
            let x = MLXFast.rmsNorm(h, weight: layer.inputNorm, eps: configuration.epsilon)
            if let attention = layer.attention {
                h = h + attend(x, attention)
            } else if let linear = layer.linear {
                h = h + recur(x, linear)
            }
            let y = MLXFast.rmsNorm(h, weight: layer.postNorm, eps: configuration.epsilon)
            h = h + layer.down(silu(layer.gate(y)) * layer.up(y))
        }
        let last = h[0, h.dim(1) - 1]
        return MLXFast.rmsNorm(last, weight: norm, eps: configuration.epsilon)
    }

    /// Full attention with an output gate and partial rotary positions, causal.
    private func attend(_ x: MLXArray, _ p: Attention) -> MLXArray {
        let c = configuration
        let (B, T) = (x.dim(0), x.dim(1))
        let projected = p.q(x).reshaped(B, T, c.heads, 2 * c.headDim)
        let parts = split(projected, indices: [c.headDim], axis: -1)
        let gate = parts[1].reshaped(B, T, c.heads * c.headDim)
        var queries = MLXFast.rmsNorm(parts[0], weight: p.qNorm, eps: c.epsilon).transposed(0, 2, 1, 3)
        var keys = MLXFast.rmsNorm(p.k(x).reshaped(B, T, c.kvHeads, c.headDim), weight: p.kNorm, eps: c.epsilon)
            .transposed(0, 2, 1, 3)
        let values = p.v(x).reshaped(B, T, c.kvHeads, c.headDim).transposed(0, 2, 1, 3)
        // Text positions are equal in all three M-RoPE sections, so this is plain RoPE on the
        // first rotary dimensions (rotate-half pairing), the rest passed through.
        queries = MLXFast.RoPE(queries, dimensions: c.rotaryDimensions, traditional: false, base: c.ropeTheta, scale: 1, offset: 0)
        keys = MLXFast.RoPE(keys, dimensions: c.rotaryDimensions, traditional: false, base: c.ropeTheta, scale: 1, offset: 0)
        let output = MLXFast.scaledDotProductAttention(
            queries: queries, keys: keys, values: values, scale: 1 / Float(c.headDim).squareRoot(), mask: .causal)
            .transposed(0, 2, 1, 3).reshaped(B, T, c.heads * c.headDim)
        return p.o(output * sigmoid(gate))
    }

    /// Gated DeltaNet: a causal depthwise convolution, then the gated delta rule recurrence.
    private func recur(_ x: MLXArray, _ p: LinearAttention) -> MLXArray {
        let c = configuration
        let (B, T) = (x.dim(0), x.dim(1))
        let keyWidth = c.linearKeyHeads * c.linearKeyDim
        let mixed = p.qkv(x)                                                     // [B, T, channels]
        let z = p.z(x).reshaped(B, T, c.linearValueHeads, c.linearValueDim)
        let b = p.b(x), a = p.a(x)

        // Causal depthwise convolution over time, zero history: y[t] = Σ_j x[t + j - (K-1)] · w[j],
        // accumulated in float32 as MLX's convolution does.
        let K = c.convolutionKernel
        let padded = concatenated([MLXArray.zeros([B, K - 1, mixed.dim(2)], dtype: .float32), mixed.asType(.float32)], axis: 1)
        let weight = p.convolution.asType(.float32)
        var convolved = padded[0..., 0 ..< T] * weight[0..., 0]
        for j in 1 ..< K { convolved = convolved + padded[0..., j ..< (j + T)] * weight[0..., j] }
        convolved = silu(convolved.asType(mixed.dtype))

        let pieces = split(convolved, indices: [keyWidth, 2 * keyWidth], axis: -1)
        let ones = MLXArray.ones([c.linearKeyDim], dtype: x.dtype)
        let scale = 1 / Float(c.linearKeyDim).squareRoot()
        let q = (scale * scale) * MLXFast.rmsNorm(pieces[0].reshaped(B, T, c.linearKeyHeads, c.linearKeyDim), weight: ones, eps: 1e-6)
        let k = scale * MLXFast.rmsNorm(pieces[1].reshaped(B, T, c.linearKeyHeads, c.linearKeyDim), weight: ones, eps: 1e-6)
        let v = pieces[2].reshaped(B, T, c.linearValueHeads, c.linearValueDim)

        let g = exp(-exp(p.aLog.asType(.float32)) * softplus(a + p.dtBias))
        let beta = sigmoid(b)
        let state = MLXArray.zeros([B, c.linearValueHeads, c.linearValueDim, c.linearKeyDim], dtype: .float32)
        let y = GatedDelta.run(q: q.asType(x.dtype), k: k.asType(x.dtype), v: v, g: g, beta: beta, state: state)

        // RMSNormGated: normalize, then gate with silu(z) in float32.
        let normalized = MLXFast.rmsNorm(y, weight: p.norm, eps: c.epsilon)
        let gated = (silu(z.asType(.float32)) * normalized.asType(.float32)).asType(y.dtype)
        return p.out(gated.reshaped(B, T, c.linearValueHeads * c.linearValueDim))
    }
}

private func softplus(_ x: MLXArray) -> MLXArray { logAddExp(x, MLXArray.zeros(like: x)) }
private func silu(_ x: MLXArray) -> MLXArray { x * sigmoid(x) }
