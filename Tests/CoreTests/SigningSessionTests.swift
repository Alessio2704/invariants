import Foundation
import Testing

@testable import Core

@Suite("Signing Key Resolver & Signing Session Tests", .tags(.unit))
struct SigningSessionTests {

  @Test("SigningError errorDescription produces clear, actionable messages")
  func signingErrorDescriptions() {
    let err1 = SigningError.keyNotFound("/path/to/missing")
    #expect(err1.errorDescription?.contains("Signing key not found at /path/to/missing") == true)
    #expect(err1.errorDescription?.contains("Run 'invariants key generate'") == true)

    let err2 = SigningError.publicKeyMissing("/path/to/missing.pub")
    #expect(err2.errorDescription?.contains("Public key file not found at /path/to/missing.pub") == true)

    let err3 = SigningError.unauthorizedSigner(publicKey: "ssh-ed25519 AAA...", allowedSignersPath: "/repo/signers")
    #expect(err3.errorDescription?.contains("Signing key is not authorized in /repo/signers") == true)
    #expect(err3.errorDescription?.contains("ssh-ed25519 AAA...") == true)
  }

  @Test("SigningKeyResolver.resolveKey resolves custom path when file exists")
  func resolveKeyCustomPathSuccess() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("resolve_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let keyURL = tmpDir.appendingPathComponent("my_key")
    try "dummy".write(to: keyURL, atomically: true, encoding: .utf8)

    let resolved = try SigningKeyResolver.resolveKey(customPath: keyURL.path, environment: [:])
    #expect(resolved.path == keyURL.path)
  }

  @Test("SigningKeyResolver.resolveKey strictly throws keyNotFound on missing custom path without fallback")
  func resolveKeyCustomPathMissingThrows() {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("resolve_test_\(UUID().uuidString)")
    let missingPath = tmpDir.appendingPathComponent("does_not_exist").path

    #expect(throws: SigningError.self) {
      _ = try SigningKeyResolver.resolveKey(
        customPath: missingPath,
        environment: ["INVARIANTS_KEY": "/another/path"]
      )
    }
  }

  @Test("SigningKeyResolver.resolveKey resolves INVARIANTS_KEY environment variable when customPath is nil or empty")
  func resolveKeyEnvironmentSuccess() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("resolve_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let envKeyURL = tmpDir.appendingPathComponent("ci_key")
    try "dummy".write(to: envKeyURL, atomically: true, encoding: .utf8)

    // With nil customPath
    let resolvedNil = try SigningKeyResolver.resolveKey(
      customPath: nil,
      environment: ["INVARIANTS_KEY": envKeyURL.path]
    )
    #expect(resolvedNil.path == envKeyURL.path)

    // With empty customPath
    let resolvedEmpty = try SigningKeyResolver.resolveKey(
      customPath: "",
      environment: ["INVARIANTS_KEY": envKeyURL.path]
    )
    #expect(resolvedEmpty.path == envKeyURL.path)
  }

  @Test("SigningKeyResolver.resolveKey strictly throws keyNotFound on missing INVARIANTS_KEY without fallback")
  func resolveKeyEnvironmentMissingThrows() {
    #expect(throws: SigningError.self) {
      _ = try SigningKeyResolver.resolveKey(
        customPath: nil,
        environment: ["INVARIANTS_KEY": "/missing/ci/key"]
      )
    }
  }

  @Test("SigningSession.authorize throws keyNotFound when private key does not exist")
  func authorizeMissingPrivateKey() {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("session_test_\(UUID().uuidString)")
    let missingKey = tmpDir.appendingPathComponent("missing_priv")

    #expect(throws: SigningError.self) {
      _ = try SigningSession.authorize(customPath: missingKey.path)
    }
  }

  @Test("SigningSession.authorize throws publicKeyMissing when .pub file does not exist")
  func authorizeMissingPublicKey() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("session_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let privKey = tmpDir.appendingPathComponent("id_priv")
    try "dummy-private".write(to: privKey, atomically: true, encoding: .utf8)

    #expect(throws: SigningError.self) {
      _ = try SigningSession.authorize(customPath: privKey.path)
    }
  }

  @Test("SigningSession.authorize throws publicKeyMissing when .pub file is empty")
  func authorizeEmptyPublicKey() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("session_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let privKey = tmpDir.appendingPathComponent("id_priv")
    let pubKey = tmpDir.appendingPathComponent("id_priv.pub")
    try "dummy-private".write(to: privKey, atomically: true, encoding: .utf8)
    try "   \n  \t ".write(to: pubKey, atomically: true, encoding: .utf8)

    #expect(throws: SigningError.self) {
      _ = try SigningSession.authorize(customPath: privKey.path)
    }
  }

  @Test("SigningSession.authorize throws unauthorizedSigner when allowed_signers is missing or signer not in it")
  func authorizeUnauthorizedSigner() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("session_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let privKey = tmpDir.appendingPathComponent("id_priv")
    try SigningClient.generateThrowawayKey(at: privKey)

    let repoRoot = tmpDir.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)

    // Case 1: allowed_signers missing
    #expect(throws: SigningError.self) {
      _ = try SigningSession.authorize(customPath: privKey.path, in: repoRoot)
    }

    // Case 2: allowed_signers exists but does not contain the key
    let signersDir = repoRoot.appendingPathComponent("invariants")
    try FileManager.default.createDirectory(at: signersDir, withIntermediateDirectories: true)
    let signersURL = signersDir.appendingPathComponent("allowed_signers")
    try
      "other-user@plans.app namespaces=\"invariants\" ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBDUMMY=\n"
      .write(
        to: signersURL, atomically: true, encoding: .utf8
      )

    #expect(throws: SigningError.self) {
      _ = try SigningSession.authorize(customPath: privKey.path, in: repoRoot)
    }
  }

  @Test("SigningSession.authorize throws unauthorizedSigner when signer is expired")
  func authorizeExpiredSignerThrows() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("session_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let privKey = tmpDir.appendingPathComponent("id_priv")
    try SigningClient.generateThrowawayKey(at: privKey)
    let pubStr = try privKey.appendingPathExtension("pub").readTrimmedUTF8()

    let repoRoot = tmpDir.appendingPathComponent("repo")
    let signersDir = repoRoot.appendingPathComponent("invariants")
    try FileManager.default.createDirectory(at: signersDir, withIntermediateDirectories: true)
    let signersURL = signersDir.appendingPathComponent("allowed_signers")

    // Expired in 2020
    let expiredLine = "* namespaces=\"invariants\",valid-before=\"20200101000000\" \(pubStr)\n"
    try expiredLine.write(to: signersURL, atomically: true, encoding: .utf8)

    #expect(throws: SigningError.self) {
      _ = try SigningSession.authorize(customPath: privKey.path, in: repoRoot)
    }
  }

  @Test("SigningSession.authorize succeeds when signer is active in allowed_signers")
  func authorizeActiveSignerSuccess() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("session_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let privKey = tmpDir.appendingPathComponent("id_priv")
    try SigningClient.generateThrowawayKey(at: privKey)
    let pubURL = privKey.appendingPathExtension("pub")
    let pubStr = try pubURL.readTrimmedUTF8()

    let repoRoot = tmpDir.appendingPathComponent("repo")
    let signersDir = repoRoot.appendingPathComponent("invariants")
    try FileManager.default.createDirectory(at: signersDir, withIntermediateDirectories: true)
    let signersURL = signersDir.appendingPathComponent("allowed_signers")

    let activeLine = "* namespaces=\"invariants\" \(pubStr)\n"
    try activeLine.write(to: signersURL, atomically: true, encoding: .utf8)

    let session = try SigningSession.authorize(customPath: privKey.path, in: repoRoot)
    #expect(session.privateKeyURL.path == privKey.path)
    #expect(session.publicKey == pubStr)
    #expect(session.publicKeyURL.path == pubURL.path)
  }

  @Test("SigningSession.authorize with skipAllowedSignersCheck succeeds without allowed_signers file")
  func authorizeSkipAllowedSignersCheck() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("session_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let privKey = tmpDir.appendingPathComponent("id_priv")
    try SigningClient.generateThrowawayKey(at: privKey)
    let pubStr = try privKey.appendingPathExtension("pub").readTrimmedUTF8()

    let repoRoot = tmpDir.appendingPathComponent("empty_repo")
    try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)

    let session = try SigningSession.authorize(
      customPath: privKey.path,
      in: repoRoot,
      skipAllowedSignersCheck: true
    )
    #expect(session.privateKeyURL.path == privKey.path)
    #expect(session.publicKey == pubStr)
  }
}
