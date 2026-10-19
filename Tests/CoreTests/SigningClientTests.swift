import CryptoKit
import Foundation
import Testing

@testable import Core

@Suite("SigningClient Secure Enclave & P-256 Tests")
struct SigningClientTests {
  @Test("OpenSSH wire format serialization and fingerprinting")
  func testPublicKeySerialization() async throws {
    let key = P256.Signing.PrivateKey()
    let pubLine = SSHSIG.formatOpenSSHPublicKey(key.publicKey, comment: "test-user@invariants")

    #expect(pubLine.hasPrefix("ecdsa-sha2-nistp256 "))
    #expect(pubLine.contains(" test-user@invariants"))

    let tmpPub = FileManager.default.temporaryDirectory
      .appendingPathComponent("test_pub_\(UUID().uuidString).pub")
    try pubLine.write(to: tmpPub, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tmpPub) }

    let fp = try SigningClient.fingerprint(pubKeyURL: tmpPub)
    #expect(fp.hasPrefix("SHA256:"))
  }

  @Test("CryptoKit P-256 sign and OpenSSH ssh-keygen -Y verify round-trip")
  func testSignAndVerifyRoundTrip() async throws {
    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("test_cryptokit_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let keyURL = tmpDir.appendingPathComponent("signing_key")
    let pubURL = keyURL.appendingPathExtension("pub")
    let messageURL = tmpDir.appendingPathComponent("registry.lock")
    let signersURL = tmpDir.appendingPathComponent("allowed_signers")

    try SigningClient.generateThrowawayKey(at: keyURL, comment: "lead@plans")

    let messageContent = "{\"version\":1,\"rules\":[]}\n"
    try messageContent.write(to: messageURL, atomically: true, encoding: .utf8)

    let pubKeyContent = try pubURL.readTrimmedUTF8()
    let signersContent = "* namespaces=\"invariants\" \(pubKeyContent)\n"
    try signersContent.write(to: signersURL, atomically: true, encoding: .utf8)

    // Sign using CryptoKit
    try await SigningClient.sign(keyURL: keyURL, namespace: "invariants", fileURL: messageURL)

    let sigURL = messageURL.appendingPathExtension("sig")
    #expect(FileManager.default.fileExists(atPath: sigURL.path))

    let sigContent = try sigURL.readUTF8()
    #expect(sigContent.contains("-----BEGIN SSH SIGNATURE-----"))
    #expect(sigContent.contains("-----END SSH SIGNATURE-----"))

    // Verify using standard OpenSSH ssh-keygen -Y verify
    let isValid = try await SigningClient.verify(
      allowedSignersURL: signersURL,
      identity: "lead@plans",
      namespace: "invariants",
      signatureURL: sigURL,
      fileURL: messageURL
    )
    #expect(isValid == true)
  }

  @Test("Tampered message fails OpenSSH verification")
  func testTamperedMessageFails() async throws {
    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("test_tamper_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let keyURL = tmpDir.appendingPathComponent("signing_key")
    let pubURL = keyURL.appendingPathExtension("pub")
    let messageURL = tmpDir.appendingPathComponent("registry.lock")
    let signersURL = tmpDir.appendingPathComponent("allowed_signers")

    try SigningClient.generateThrowawayKey(at: keyURL, comment: "lead@plans")

    let messageContent = "{\"version\":1,\"rules\":[]}\n"
    try messageContent.write(to: messageURL, atomically: true, encoding: .utf8)

    let pubKeyContent = try pubURL.readTrimmedUTF8()
    let signersContent = "* namespaces=\"invariants\" \(pubKeyContent)\n"
    try signersContent.write(to: signersURL, atomically: true, encoding: .utf8)

    try await SigningClient.sign(keyURL: keyURL, namespace: "invariants", fileURL: messageURL)

    // Tamper with the message
    try "{\"version\":2,\"rules\":[]}\n".write(to: messageURL, atomically: true, encoding: .utf8)

    let sigURL = messageURL.appendingPathExtension("sig")
    let isValid = try await SigningClient.verify(
      allowedSignersURL: signersURL,
      identity: "lead@plans",
      namespace: "invariants",
      signatureURL: sigURL,
      fileURL: messageURL
    )
    #expect(isValid == false)
  }

  @Test("Namespace mismatch fails OpenSSH verification")
  func testNamespaceMismatchFails() async throws {
    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("test_namespace_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let keyURL = tmpDir.appendingPathComponent("signing_key")
    let pubURL = keyURL.appendingPathExtension("pub")
    let messageURL = tmpDir.appendingPathComponent("registry.lock")
    let signersURL = tmpDir.appendingPathComponent("allowed_signers")

    try SigningClient.generateThrowawayKey(at: keyURL, comment: "lead@plans")

    let messageContent = "{\"version\":1,\"rules\":[]}\n"
    try messageContent.write(to: messageURL, atomically: true, encoding: .utf8)

    let pubKeyContent = try pubURL.readTrimmedUTF8()
    let signersContent = "* namespaces=\"invariants\" \(pubKeyContent)\n"
    try signersContent.write(to: signersURL, atomically: true, encoding: .utf8)

    try await SigningClient.sign(keyURL: keyURL, namespace: "invariants", fileURL: messageURL)

    let sigURL = messageURL.appendingPathExtension("sig")
    // Attempt verification with "git" namespace instead of "invariants"
    let isValid = try await SigningClient.verify(
      allowedSignersURL: signersURL,
      identity: "lead@plans",
      namespace: "git",
      signatureURL: sigURL,
      fileURL: messageURL
    )
    #expect(isValid == false)
  }
}
