import CryptoKit
import Foundation

// Ephemeral test keys only; never print or store a production credential.
let root = URL(filePath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedString().write(to: root.appending(path: "private.key"), atomically: true, encoding: .utf8)
try key.publicKey.rawRepresentation.base64EncodedString().write(to: root.appending(path: "public.key"), atomically: true, encoding: .utf8)
