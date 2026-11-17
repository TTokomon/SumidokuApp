import Foundation
import CryptoKit

// Test-only key. Only the public key is written to stdout; the seed stays private.
let folder = URL(fileURLWithPath:CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
let secret = folder.appendingPathComponent("test-signing-seed")
try Data(key.rawRepresentation.base64EncodedString().utf8).write(to:secret,options:.atomic)
try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:secret.path)
try Data(key.publicKey.rawRepresentation.base64EncodedString().utf8).write(to:folder.appendingPathComponent("test-public-key"))
