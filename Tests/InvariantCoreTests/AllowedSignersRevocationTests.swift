import Foundation
import Testing

@testable import InvariantCore

@Suite("Allowed Signers & Revocation Cryptographic Tests", .tags(.unit))
struct AllowedSignersRevocationTests {

  @Test("Soft revocation rejects signature when verify time > valid-before")
  func softRevocationRejection() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("soft_rev_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let keyURL = tmpDir.appendingPathComponent("id_rev_p256")
    let signingClient = SigningClient()
    try signingClient.generateThrowawayKey(at: keyURL)

    let pubKeyData = try Data(contentsOf: tmpDir.appendingPathComponent("id_rev_p256.pub"))
    let pubKeyStr = (String(bytes: pubKeyData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

    let repoDir = tmpDir.appendingPathComponent("repo")
    let invariantsDir = repoDir.appendingPathComponent("invariants")
    try FileManager.default.createDirectory(at: invariantsDir, withIntermediateDirectories: true)

    // Set valid-before to a timestamp in the distant past (2020-01-01)
    let allowedSignersURL = RegistryManager.allowedSignersURL(repoRoot: repoDir)
    let signersContent = "* namespaces=\"invariants\",valid-before=\"20200101000000\" \(pubKeyStr)\n"
    try Data(signersContent.utf8).write(to: allowedSignersURL)

    let fakeEnv = SystemEnvironment(rootURL: tmpDir)
    let manager = RegistryManager(environment: fakeEnv, signingClient: signingClient)

    let reg = Registry(version: 1, engine: "^1.0.0")
    try await manager.saveAndSign(registry: reg, repoRoot: repoDir, keyURL: keyURL)

    // loadAndVerify must reject expired key
    await #expect(throws: RegistryError.self) {
      _ = try await manager.loadAndVerify(repoRoot: repoDir, installedEngineVersion: "1.0.0")
    }
  }

  @Test("Premature key is rejected when verify time < valid-after")
  func prematureKeyRejection() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("premature_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let keyURL = tmpDir.appendingPathComponent("id_pre_p256")
    let signingClient = SigningClient()
    try signingClient.generateThrowawayKey(at: keyURL)

    let pubKeyData = try Data(contentsOf: tmpDir.appendingPathComponent("id_pre_p256.pub"))
    let pubKeyStr = (String(bytes: pubKeyData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

    let repoDir = tmpDir.appendingPathComponent("repo")
    let invariantsDir = repoDir.appendingPathComponent("invariants")
    try FileManager.default.createDirectory(at: invariantsDir, withIntermediateDirectories: true)

    // Set valid-after to a timestamp in the distant future (2035-01-01)
    let allowedSignersURL = RegistryManager.allowedSignersURL(repoRoot: repoDir)
    let signersContent = "* namespaces=\"invariants\",valid-after=\"20350101000000\" \(pubKeyStr)\n"
    try Data(signersContent.utf8).write(to: allowedSignersURL)

    let fakeEnv = SystemEnvironment(rootURL: tmpDir)
    let manager = RegistryManager(environment: fakeEnv, signingClient: signingClient)

    let reg = Registry(version: 1, engine: "^1.0.0")
    try await manager.saveAndSign(registry: reg, repoRoot: repoDir, keyURL: keyURL)

    // loadAndVerify must reject not-yet-valid key
    await #expect(throws: RegistryError.self) {
      _ = try await manager.loadAndVerify(repoRoot: repoDir, installedEngineVersion: "1.0.0")
    }
  }

  @Test("Signers hash tampering is detected and rejected")
  func signersHashTamperingDetected() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("tamper_signers_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let keyURL = tmpDir.appendingPathComponent("id_valid_p256")
    let signingClient = SigningClient()
    try signingClient.generateThrowawayKey(at: keyURL)

    let pubKeyData = try Data(contentsOf: tmpDir.appendingPathComponent("id_valid_p256.pub"))
    let pubKeyStr = (String(bytes: pubKeyData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

    let repoDir = tmpDir.appendingPathComponent("repo")
    let invariantsDir = repoDir.appendingPathComponent("invariants")
    try FileManager.default.createDirectory(at: invariantsDir, withIntermediateDirectories: true)

    let allowedSignersURL = RegistryManager.allowedSignersURL(repoRoot: repoDir)
    let signersContent = "* namespaces=\"invariants\" \(pubKeyStr)\n"
    try Data(signersContent.utf8).write(to: allowedSignersURL)

    let fakeEnv = SystemEnvironment(rootURL: tmpDir)
    let manager = RegistryManager(environment: fakeEnv, signingClient: signingClient)

    let reg = Registry(version: 1, engine: "^1.0.0")
    try await manager.saveAndSign(registry: reg, repoRoot: repoDir, keyURL: keyURL)

    // Valid initially
    let loaded = try await manager.loadAndVerify(repoRoot: repoDir, installedEngineVersion: "1.0.0")
    #expect(loaded.version == 1)

    // Tamper allowed_signers in working tree (e.g. Rogue AI appends key)
    let rogueKey =
      "* namespaces=\"invariants\" ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBAc9 rogue@ai\n"
    var tamperedSigners = signersContent
    tamperedSigners.append(rogueKey)
    try tamperedSigners.write(to: allowedSignersURL, atomically: true, encoding: .utf8)

    // loadAndVerify must immediately throw signatureInvalid due to signers hash mismatch
    await #expect(throws: RegistryError.self) {
      _ = try await manager.loadAndVerify(repoRoot: repoDir, installedEngineVersion: "1.0.0")
    }
  }

  @Test("Hard revocation: purged key is rejected by OpenSSH verify")
  func hardRevocationPurgeRejection() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("hard_rev_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let signingClient = SigningClient()

    // 1. Generate Key A (senior) and Key B (to be revoked)
    let keyA = tmpDir.appendingPathComponent("id_senior")
    let keyB = tmpDir.appendingPathComponent("id_revoked")
    try signingClient.generateThrowawayKey(at: keyA)
    try signingClient.generateThrowawayKey(at: keyB)

    let pubA = (try String(contentsOf: tmpDir.appendingPathComponent("id_senior.pub"), encoding: .utf8))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let pubB = (try String(contentsOf: tmpDir.appendingPathComponent("id_revoked.pub"), encoding: .utf8))
      .trimmingCharacters(in: .whitespacesAndNewlines)

    let repoDir = tmpDir.appendingPathComponent("repo")
    let invariantsDir = repoDir.appendingPathComponent("invariants")
    try FileManager.default.createDirectory(at: invariantsDir, withIntermediateDirectories: true)

    // 2. Initial signers has both A and B
    let allowedSignersURL = RegistryManager.allowedSignersURL(repoRoot: repoDir)
    let initialSigners = "* namespaces=\"invariants\" \(pubA)\n* namespaces=\"invariants\" \(pubB)\n"
    try initialSigners.write(to: allowedSignersURL, atomically: true, encoding: .utf8)

    let fakeEnv = SystemEnvironment(rootURL: tmpDir)
    let manager = RegistryManager(environment: fakeEnv, signingClient: signingClient)

    let reg = Registry(version: 1, engine: "^1.0.0")
    try await manager.saveAndSign(registry: reg, repoRoot: repoDir, keyURL: keyB)

    // Initially valid when signed by B
    let loaded1 = try await manager.loadAndVerify(repoRoot: repoDir, installedEngineVersion: "1.0.0")
    #expect(loaded1.version == 1)

    // 3. Senior A hard revokes B: purges B completely from allowed_signers and bumps to v2
    let purgedSigners = "* namespaces=\"invariants\" \(pubA)\n"
    try purgedSigners.write(to: allowedSignersURL, atomically: true, encoding: .utf8)

    var reg2 = reg
    reg2.version = 2
    try await manager.saveAndSign(registry: reg2, repoRoot: repoDir, keyURL: keyA)

    // Verified with Senior A's signature
    let loaded2 = try await manager.loadAndVerify(repoRoot: repoDir, installedEngineVersion: "1.0.0")
    #expect(loaded2.version == 2)

    // 4. Revoked B tries to forge a signature on registry v3
    var reg3 = reg2
    reg3.version = 3
    let lockURL = RegistryManager.registryURL(repoRoot: repoDir)
    let lockData = try #require(CanonicalJSON.serialize(reg3).data(using: .utf8))
    try lockData.write(to: lockURL)
    try await signingClient.sign(keyURL: keyB, namespace: "invariants", fileURL: lockURL)

    // loadAndVerify must reject because Key B is not in allowed_signers
    await #expect(throws: RegistryError.self) {
      _ = try await manager.loadAndVerify(repoRoot: repoDir, installedEngineVersion: "1.0.0")
    }
  }

  @Test("FloorGuard ancestry check: rejects signature from signer not present in parent commit")
  func ancestryCheckRejection() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ancestry_\(UUID().uuidString)")
    let repoURL = tmpDir.appendingPathComponent("repo")
    let fakeRoot = tmpDir.appendingPathComponent("fake_root")
    try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: fakeRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let runner = SubprocessRunner()
    _ = try await runner.run(
      binary: .git, arguments: ["-C", repoURL.path, "init", "-b", "main"])
    _ = try await runner.run(
      binary: .git, arguments: ["-C", repoURL.path, "config", "user.name", "Senior"])
    _ = try await runner.run(
      binary: .git,
      arguments: ["-C", repoURL.path, "config", "user.email", "senior@plans.local"])

    let signingClient = SigningClient()
    let seniorKey = tmpDir.appendingPathComponent("id_senior")
    let rogueKey = tmpDir.appendingPathComponent("id_rogue")
    try signingClient.generateThrowawayKey(at: seniorKey)
    try signingClient.generateThrowawayKey(at: rogueKey)

    let seniorPub = (try String(contentsOf: tmpDir.appendingPathComponent("id_senior.pub"), encoding: .utf8))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let roguePub = (try String(contentsOf: tmpDir.appendingPathComponent("id_rogue.pub"), encoding: .utf8))
      .trimmingCharacters(in: .whitespacesAndNewlines)

    let invariantsDir = repoURL.appendingPathComponent("invariants")
    try FileManager.default.createDirectory(at: invariantsDir, withIntermediateDirectories: true)

    // Commit 1: Version 1 with senior key in allowed_signers
    let allowedSignersURL = RegistryManager.allowedSignersURL(repoRoot: repoURL)
    let initialSigners = "* namespaces=\"invariants\" \(seniorPub)\n"
    try initialSigners.write(to: allowedSignersURL, atomically: true, encoding: .utf8)

    let fakeEnv = SystemEnvironment(rootURL: fakeRoot)
    let manager = RegistryManager(environment: fakeEnv, signingClient: signingClient)

    let reg1 = Registry(version: 1, engine: "^1.0.0")
    try await manager.saveAndSign(registry: reg1, repoRoot: repoURL, keyURL: seniorKey)

    let gitClient = GitClient()
    try await gitClient.commit(repoRoot: repoURL, paths: ["."], message: "v1 by senior")

    // Rogue AI creates v2: adds rogue key to allowed_signers, bumps version, signs with rogueKey
    let rogueSigners = initialSigners + "* namespaces=\"invariants\" \(roguePub)\n"
    try rogueSigners.write(to: allowedSignersURL, atomically: true, encoding: .utf8)

    var reg2 = reg1
    reg2.version = 2
    // Manager saves and signs with rogueKey
    try await manager.saveAndSign(registry: reg2, repoRoot: repoURL, keyURL: rogueKey)

    let floorGuard = FloorGuard(gitClient: gitClient)
    let lockURL = RegistryManager.registryURL(repoRoot: repoURL)
    let sigURL = RegistryManager.signatureURL(repoRoot: repoURL)

    // FloorGuard ancestry check must catch that rogueKey was not in Commit 1's allowed_signers!
    await #expect(throws: FloorError.self) {
      try await floorGuard.checkSignerAncestry(
        repoRoot: repoURL,
        currentRegistry: reg2,
        lockURL: lockURL,
        sigURL: sigURL,
        signingClient: signingClient
      )
    }
  }
}
