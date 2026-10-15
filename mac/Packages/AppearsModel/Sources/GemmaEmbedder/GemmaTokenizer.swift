import Foundation

/// Gemma's BPE tokenizer, built from the model's `tokenizer.json`.
///
/// swift-transformers' generic BPE rescans the whole text and rebuilds its set of pairs for
/// every merge. Gemma's normalizer turns spaces into "▁" before its pre-tokenizer splits on
/// spaces, so the whole document is one word, and a 1,400-character window took about 40 ms:
/// most of indexing time. This follows Hugging Face `tokenizers` (`word.rs`) instead: a heap
/// of candidate merges, lowest rank first, then leftmost, which is O(n log n).
///
/// It covers what Gemma's tokenizer.json uses: the " " → "▁" normalizer, BPE over Unicode
/// scalars with byte fallback, and `<bos>` … `<eos>` around the result. Text containing an
/// added token (`<bos>`, `<|image|>` …) returns nil, and callers use the full tokenizer.
///
/// Vocabulary keys are compared as UTF-8 bytes. Swift's `String` equality is canonical, so
/// it would treat "é" and "e" + U+0301, which are different tokens, as one.
public final class GemmaTokenizer: Sendable {
    /// Tokens that are a single Unicode scalar.
    private let scalarIDs: [UInt32: Int32]
    /// `<0x00>` … `<0xFF>`.
    private let byteIDs: [Int32]
    /// Left and right token IDs (`left << 32 | right`) to the merge's rank and the merged ID.
    private let merges: [UInt64: Merge]
    /// The merged token ID for each rank, to check a queued merge still applies.
    private let mergedIDs: [Int32]
    private let addedTokens: [String]
    public let bos: Int
    public let eos: Int

    private struct Merge {
        let rank: Int32
        let id: Int32
    }

    public enum LoadError: Error {
        case unsupported(String)
    }

    public init(contentsOf url: URL) throws {
        // Foundation's JSON can't be used: bridging to String/NSString merges canonically
        // equivalent keys and drops U+FEFF, losing tokens. RawJSON keeps strings as UTF-8.
        let json = try RawJSON.parse(Data(contentsOf: url))
        guard let model = json["model"], model["type"]?.text == "BPE",
              case .object(let vocab)? = model["vocab"], case .array(let mergeList)? = model["merges"]
        else { throw LoadError.unsupported("not a BPE tokenizer.json") }
        guard model["byte_fallback"] == .bool(true), model["ignore_merges"] != .bool(true),
              (model["continuing_subword_prefix"] ?? .null) == .null, (model["end_of_word_suffix"] ?? .null) == .null
        else { throw LoadError.unsupported("BPE options other than Gemma's") }
        guard let normalizer = json["normalizer"], normalizer["type"]?.text == "Replace",
              normalizer["pattern"]?["String"]?.text == " ", normalizer["content"]?.text == "\u{2581}"
        else { throw LoadError.unsupported("a normalizer other than Gemma's") }

        var byUTF8: [[UInt8]: Int32] = [:]
        byUTF8.reserveCapacity(vocab.count)
        var scalarIDs: [UInt32: Int32] = [:]
        for (token, value) in vocab {
            guard case .number(let id) = value else { throw LoadError.unsupported("vocabulary entry") }
            byUTF8[token] = Int32(id)
            let scalars = String(decoding: token, as: UTF8.self).unicodeScalars
            if scalars.count == 1, let scalar = scalars.first { scalarIDs[scalar.value] = Int32(id) }
        }
        self.scalarIDs = scalarIDs

        byteIDs = try (0..<256).map { byte in
            guard let id = byUTF8[Array(String(format: "<0x%02X>", byte).utf8)] else {
                throw LoadError.unsupported("missing byte token \(byte)")
            }
            return id
        }

        var merges: [UInt64: Merge] = [:]
        merges.reserveCapacity(mergeList.count)
        var mergedIDs: [Int32] = []
        mergedIDs.reserveCapacity(mergeList.count)
        for (rank, entry) in mergeList.enumerated() {
            let left: [UInt8], right: [UInt8]
            switch entry {
            case .array(let pair) where pair.count == 2:
                guard case .string(let a) = pair[0], case .string(let b) = pair[1] else { throw LoadError.unsupported("merge \(rank)") }
                (left, right) = (a, b)
            case .string(let joined):
                guard let space = joined.firstIndex(of: 0x20) else { throw LoadError.unsupported("merge \(rank)") }
                (left, right) = (Array(joined[..<space]), Array(joined[(space + 1)...]))
            default:
                throw LoadError.unsupported("merge \(rank)")
            }
            guard let leftID = byUTF8[left], let rightID = byUTF8[right], let merged = byUTF8[left + right] else {
                throw LoadError.unsupported("merge \(rank) names a token that isn't in the vocabulary")
            }
            // Like `tokenizers`, a pair listed twice keeps its last rank.
            merges[Self.key(leftID, rightID)] = Merge(rank: Int32(rank), id: merged)
            mergedIDs.append(merged)
        }
        self.merges = merges
        self.mergedIDs = mergedIDs

        guard case .array(let added)? = json["added_tokens"] else { throw LoadError.unsupported("no added tokens") }
        let contents = added.compactMap { token -> (String, Int)? in
            guard let text = token["content"]?.text, case .number(let id)? = token["id"] else { return nil }
            return (text, id)
        }
        addedTokens = contents.map(\.0)
        guard let bos = contents.first(where: { $0.0 == "<bos>" })?.1, let eos = contents.first(where: { $0.0 == "<eos>" })?.1
        else { throw LoadError.unsupported("no <bos> or <eos>") }
        self.bos = bos
        self.eos = eos
    }

    /// Token IDs with `<bos>` and `<eos>`, or nil if the text contains an added token.
    public func encode(_ text: String) -> [Int]? {
        for token in addedTokens where text.contains(token) {
            // `contains` is canonical too, which can only cause a needless fallback.
            return nil
        }

        // Symbols as a linked list over an array: token ID, and the previous and next live
        // positions. A merged-away symbol gets id -1.
        var ids: [Int32] = []
        ids.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            let value = scalar.value == 0x20 ? 0x2581 : scalar.value
            if let id = scalarIDs[value] {
                ids.append(id)
            } else {
                for byte in String(scalar).utf8 { ids.append(byteIDs[Int(byte)]) }
            }
        }
        let count = ids.count
        guard count > 1 else { return [bos] + ids.map(Int.init) + [eos] }
        var previous = (0..<count).map { Int32($0) - 1 }
        var next = (0..<count).map { $0 + 1 < count ? Int32($0 + 1) : -1 }

        // Min-heap of rank << 32 | position: lowest rank first, then leftmost.
        var heap = Heap()
        for position in 0..<(count - 1) {
            if let merge = merges[Self.key(ids[position], ids[position + 1])] {
                heap.push(UInt64(UInt32(merge.rank)) << 32 | UInt64(position))
            }
        }

        while let top = heap.pop() {
            let position = Int(top & 0xFFFF_FFFF)
            let rank = Int32(top >> 32)
            guard ids[position] >= 0 else { continue }
            let right = Int(next[position])
            // Skip it if the pair here has changed into one that makes a different token.
            guard right >= 0, let merge = merges[Self.key(ids[position], ids[right])],
                  merge.id == mergedIDs[Int(rank)] else { continue }

            ids[position] = merge.id
            ids[right] = -1
            let after = next[right]
            next[position] = after
            if after >= 0 { previous[Int(after)] = Int32(position) }

            let before = previous[position]
            if before >= 0, let left = merges[Self.key(ids[Int(before)], merge.id)] {
                heap.push(UInt64(UInt32(left.rank)) << 32 | UInt64(before))
            }
            if after >= 0, let following = merges[Self.key(merge.id, ids[Int(after)])] {
                heap.push(UInt64(UInt32(following.rank)) << 32 | UInt64(position))
            }
        }

        var result = [bos]
        result.reserveCapacity(count + 2)
        var position: Int32 = 0
        while position >= 0 {
            result.append(Int(ids[Int(position)]))
            position = next[Int(position)]
        }
        result.append(eos)
        return result
    }

    private static func key(_ left: Int32, _ right: Int32) -> UInt64 {
        UInt64(UInt32(left)) << 32 | UInt64(UInt32(right))
    }
}

/// A binary min-heap of UInt64.
private struct Heap {
    private var items: [UInt64] = []

    mutating func push(_ item: UInt64) {
        items.append(item)
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard items[child] < items[parent] else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> UInt64? {
        guard let first = items.first else { return nil }
        let last = items.removeLast()
        guard !items.isEmpty else { return first }
        items[0] = last
        var parent = 0
        while true {
            let left = parent * 2 + 1, right = left + 1
            var smallest = parent
            if left < items.count, items[left] < items[smallest] { smallest = left }
            if right < items.count, items[right] < items[smallest] { smallest = right }
            if smallest == parent { break }
            items.swapAt(parent, smallest)
            parent = smallest
        }
        return first
    }
}

/// Just enough JSON for tokenizer.json, keeping strings and object keys as raw UTF-8 and
/// objects as ordered pairs, so nothing is normalized, merged or dropped.
enum RawJSON: Equatable {
    case string([UInt8])
    case number(Int)
    case object([([UInt8], RawJSON)])
    case array([RawJSON])
    case bool(Bool)
    case null

    static func == (lhs: RawJSON, rhs: RawJSON) -> Bool {
        switch (lhs, rhs) {
        case (.string(let a), .string(let b)): a == b
        case (.number(let a), .number(let b)): a == b
        case (.bool(let a), .bool(let b)): a == b
        case (.null, .null): true
        default: false
        }
    }

    subscript(key: String) -> RawJSON? {
        guard case .object(let pairs) = self else { return nil }
        let bytes = Array(key.utf8)
        return pairs.first { $0.0 == bytes }?.1
    }

    var text: String? {
        guard case .string(let bytes) = self else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    struct SyntaxError: Error {
        let offset: Int
    }

    static func parse(_ data: Data) throws -> RawJSON {
        try data.withUnsafeBytes { buffer in
            var parser = Parser(bytes: buffer.bindMemory(to: UInt8.self))
            let value = try parser.value()
            parser.skipSpace()
            guard parser.offset == parser.bytes.count else { throw SyntaxError(offset: parser.offset) }
            return value
        }
    }

    private struct Parser {
        let bytes: UnsafeBufferPointer<UInt8>
        var offset = 0

        mutating func skipSpace() {
            while offset < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[offset]) { offset += 1 }
        }

        mutating func expect(_ byte: UInt8) throws {
            skipSpace()
            guard offset < bytes.count, bytes[offset] == byte else { throw SyntaxError(offset: offset) }
            offset += 1
        }

        mutating func value() throws -> RawJSON {
            skipSpace()
            guard offset < bytes.count else { throw SyntaxError(offset: offset) }
            switch bytes[offset] {
            case UInt8(ascii: "{"):
                offset += 1
                var pairs: [([UInt8], RawJSON)] = []
                skipSpace()
                if bytes[offset] == UInt8(ascii: "}") { offset += 1; return .object(pairs) }
                while true {
                    skipSpace()
                    let key = try string()
                    try expect(UInt8(ascii: ":"))
                    pairs.append((key, try value()))
                    skipSpace()
                    if bytes[offset] == UInt8(ascii: ",") { offset += 1; continue }
                    try expect(UInt8(ascii: "}"))
                    return .object(pairs)
                }
            case UInt8(ascii: "["):
                offset += 1
                var items: [RawJSON] = []
                skipSpace()
                if bytes[offset] == UInt8(ascii: "]") { offset += 1; return .array(items) }
                while true {
                    items.append(try value())
                    skipSpace()
                    if bytes[offset] == UInt8(ascii: ",") { offset += 1; continue }
                    try expect(UInt8(ascii: "]"))
                    return .array(items)
                }
            case UInt8(ascii: "\""):
                return .string(try string())
            case UInt8(ascii: "t"): offset += 4; return .bool(true)
            case UInt8(ascii: "f"): offset += 5; return .bool(false)
            case UInt8(ascii: "n"): offset += 4; return .null
            default:
                let start = offset
                while offset < bytes.count, "-+.eE0123456789".utf8.contains(bytes[offset]) { offset += 1 }
                // Only integers matter here (IDs); other numbers parse as 0.
                return .number(Int(String(decoding: bytes[start..<offset], as: UTF8.self)) ?? 0)
            }
        }

        mutating func string() throws -> [UInt8] {
            guard offset < bytes.count, bytes[offset] == UInt8(ascii: "\"") else { throw SyntaxError(offset: offset) }
            offset += 1
            var result: [UInt8] = []
            while offset < bytes.count {
                let byte = bytes[offset]
                offset += 1
                if byte == UInt8(ascii: "\"") { return result }
                guard byte == UInt8(ascii: "\\") else { result.append(byte); continue }
                let escape = bytes[offset]
                offset += 1
                switch escape {
                case UInt8(ascii: "n"): result.append(0x0A)
                case UInt8(ascii: "t"): result.append(0x09)
                case UInt8(ascii: "r"): result.append(0x0D)
                case UInt8(ascii: "b"): result.append(0x08)
                case UInt8(ascii: "f"): result.append(0x0C)
                case UInt8(ascii: "u"):
                    var scalar = try hex4()
                    if (0xD800..<0xDC00).contains(scalar), bytes[offset] == UInt8(ascii: "\\"), bytes[offset + 1] == UInt8(ascii: "u") {
                        offset += 2
                        let low = try hex4()
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let unicode = Unicode.Scalar(scalar) else { throw SyntaxError(offset: offset) }
                    result += Array(String(unicode).utf8)
                default: result.append(escape)  // \" \\ \/
                }
            }
            throw SyntaxError(offset: offset)
        }

        mutating func hex4() throws -> UInt32 {
            guard offset + 4 <= bytes.count, let value = UInt32(String(decoding: bytes[offset..<offset + 4], as: UTF8.self), radix: 16)
            else { throw SyntaxError(offset: offset) }
            offset += 4
            return value
        }
    }
}
