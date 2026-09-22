// Public-key-only Ed25519 verification. Does not access the Keychain.
import Foundation
import CryptoKit

guard CommandLine.arguments.count == 4,
      let keyData = Data(base64Encoded: CommandLine.arguments[1]),
      let signature = Data(base64Encoded: CommandLine.arguments[2]) else {
    fputs("Usage: swift verify-signature.swift PUBLIC_KEY SIGNATURE FILE\n", stderr)
    exit(2)
}
do {
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]), options: .mappedIfSafe)
    guard key.isValidSignature(signature, for: data) else {
        fputs("Invalid Ed25519 signature\n", stderr)
        exit(1)
    }
} catch {
    fputs("Signature verification failed: \(error)\n", stderr)
    exit(1)
}
