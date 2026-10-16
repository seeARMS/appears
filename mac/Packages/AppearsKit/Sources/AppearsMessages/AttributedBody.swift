import Foundation

/// Reads the plain text out of `message.attributedBody`.
///
/// Since macOS Ventura, Messages often leaves `message.text` empty and keeps the text only in
/// `attributedBody`: an `NSAttributedString` archived with `NSArchiver`, in Apple's old
/// "typedstream" format. `NSUnarchiver` can decode it, but it raises Objective-C exceptions
/// on anything unexpected, which Swift can't catch. So this reads just the string:
///
///     …NSString 01 94 84 01 '+' <length> <UTF-8 bytes>…
///
/// After the `NSString` class name come its version and a reference, then the value's type
/// encoding (`+`, a C string of bytes), then its length as a typedstream integer: one signed
/// byte, or 0x81 followed by 2 bytes, or 0x82 followed by 4 bytes, little-endian.
public enum AttributedBody {
    public static func string(from data: Data) -> String? {
        let bytes = [UInt8](data)
        guard let afterClassName = endOfFirstMatch(of: Array("NSString".utf8), in: bytes),
              let plus = bytes[afterClassName...].firstIndex(of: UInt8(ascii: "+"))
        else { return nil }

        var index = plus + 1
        guard index < bytes.count else { return nil }

        let length: Int
        switch bytes[index] {
        case 0x81:
            guard index + 2 < bytes.count else { return nil }
            length = Int(UInt16(bytes[index + 1]) | UInt16(bytes[index + 2]) << 8)
            index += 3
        case 0x82:
            guard index + 4 < bytes.count else { return nil }
            length = Int(
                UInt32(bytes[index + 1]) | UInt32(bytes[index + 2]) << 8
                    | UInt32(bytes[index + 3]) << 16 | UInt32(bytes[index + 4]) << 24
            )
            index += 5
        case let byte where byte < 0x80:
            length = Int(byte)
            index += 1
        default:
            return nil
        }

        guard length > 0, index + length <= bytes.count else { return nil }
        let slice = bytes[index..<(index + length)]
        return String(validating: slice, as: UTF8.self) ?? String(decoding: slice, as: UTF8.self)
    }

    private static func endOfFirstMatch(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let first = needle[0]
        var start = 0
        while start <= haystack.count - needle.count {
            guard let candidate = haystack[start...(haystack.count - needle.count)].firstIndex(of: first) else {
                return nil
            }
            if haystack[candidate..<(candidate + needle.count)].elementsEqual(needle) {
                return candidate + needle.count
            }
            start = candidate + 1
        }
        return nil
    }
}

extension String {
    /// Removes the object replacement characters (U+FFFC) Messages puts where attachments go,
    /// and trims whitespace. Returns nil when nothing is left.
    public var cleanedMessageText: String? {
        let cleaned = replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
