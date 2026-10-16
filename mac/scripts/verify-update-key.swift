import CryptoKit
import Foundation

// Validate locally; do not allow signing tools to echo malformed key material.
let environment = ProcessInfo.processInfo.environment
do {
    let raw = try String(contentsOfFile: environment["SPARKLE_PRIVATE_KEY_PATH"] ?? "", encoding: .utf8)
    guard let secret = Data(base64Encoded: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
          let expected = Data(base64Encoded: environment["SPARKLE_PUBLIC_ED_KEY"] ?? ""), expected.count == 32 else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let actual: Data
    if secret.count == 32 {
        actual = try Curve25519.Signing.PrivateKey(rawRepresentation: secret).publicKey.rawRepresentation
    } else if secret.count == 96 {
        actual = secret.suffix(32)
    } else {
        throw CocoaError(.fileReadCorruptFile)
    }
    guard actual == expected else { throw CocoaError(.fileReadCorruptFile) }
} catch {
    FileHandle.standardError.write(Data("Sparkle signing keys are invalid or do not match.\n".utf8))
    exit(1)
}
