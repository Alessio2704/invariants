import Foundation
import Testing

@testable import InvariantCore

@Suite("Engine Security & Attack Scenarios", .tags(.scenario), .tags(.security))
struct SecurityAttackTests {

  @Test("Attack 1: Rogue Agent injects public key into allowed_signers without re-signing")
  func attack1_unsignedSignersInjection() async throws {
    let repo = try await TestRepo()
    try repo.withRule("attack-rule-1")
    try await repo.signed(version: 1)

    // Attacker injects a rogue key into invariants/allowed_signers
    let signersURL = RegistryManager.allowedSignersURL(repoRoot: repo.repoURL)
    let rogueKey =
      "* namespaces=\"invariants\" ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBMockRogueKey rogue@attacker\n"
    var content = try String(contentsOf: signersURL, encoding: .utf8)
    content.append(rogueKey)
    try content.write(to: signersURL, atomically: true, encoding: .utf8)

    // loadAndVerify must immediately detect that signers_hash does not match
    let manager = RegistryManager(environment: repo.environment)
    await #expect(throws: RegistryError.self) {
      _ = try await manager.loadAndVerify(repoRoot: repo.repoURL)
    }
  }

  @Test("Attack 2: Rogue Agent generates unauthorized key, replaces signers and registry, signs with rogue key")
  func attack2_unauthorizedKeyForgedRegistry() async throws {
    let repo = try await TestRepo()
    try repo.withRule("attack-rule-2")
    try await repo.signed(version: 1)

    // Attacker generates throwaway key
    let signingClient = SigningClient()
    let rogueKeyURL = repo.repoURL.appendingPathComponent("id_rogue")
    try signingClient.generateThrowawayKey(at: rogueKeyURL)

    let roguePub = (try String(contentsOf: repo.repoURL.appendingPathComponent("id_rogue.pub"), encoding: .utf8))
      .trimmingCharacters(in: .whitespacesAndNewlines)

    // Attacker appends rogue key to allowed_signers
    let signersURL = RegistryManager.allowedSignersURL(repoRoot: repo.repoURL)
    var signersContent = try String(contentsOf: signersURL, encoding: .utf8)
    signersContent.append("* namespaces=\"invariants\" \(roguePub)\n")
    try signersContent.write(to: signersURL, atomically: true, encoding: .utf8)

    // Attacker creates version 2 registry and signs with rogueKey
    let manager = RegistryManager(environment: repo.environment, signingClient: signingClient)
    let reg2 = Registry(version: 2, engine: "^1.0.0")
    try await manager.saveAndSign(registry: reg2, repoRoot: repo.repoURL, keyURL: rogueKeyURL)

    // Ancestry verification must catch that rogueKey was not in parent commit's allowed_signers!
    let floorGuard = FloorGuard()
    let lockURL = RegistryManager.registryURL(repoRoot: repo.repoURL)
    let sigURL = RegistryManager.signatureURL(repoRoot: repo.repoURL)

    await #expect(throws: FloorError.self) {
      try await floorGuard.checkSignerAncestry(
        repoRoot: repo.repoURL,
        currentRegistry: reg2,
        lockURL: lockURL,
        sigURL: sigURL,
        signingClient: signingClient
      )
    }
  }

  @Test("Attack 3: Replay / Rollback attack resets registry.lock to an older version")
  func attack3_rollbackAttack() async throws {
    let repo = try await TestRepo()
    try repo.withRule("attack-rule-3")
    try await repo.signed(version: 1)
    try await repo.signed(version: 2)

    // Attacker attempts to revert working tree registry.lock to version 1
    let manager = RegistryManager(environment: repo.environment)
    let reg1 = Registry(version: 1, engine: "^1.0.0")
    try await manager.saveAndSign(registry: reg1, repoRoot: repo.repoURL, keyURL: repo.keyURL)

    // FloorGuard history check must reject version 1 because history max is 2
    let floorGuard = FloorGuard()
    await #expect(throws: FloorError.self) {
      _ = try await floorGuard.checkHistory(repoRoot: repo.repoURL, currentVersion: 1)
    }
  }

  @Test("Attack 4: Rule tampering / weakening causes fingerprint drift and fails check")
  func attack4_fingerprintDrift() async throws {
    let repo = try await TestRepo()
    try repo.withRule("attack-rule-4")
    try await repo.signed(version: 1)

    let manager = RegistryManager(environment: repo.environment)
    let reg = try await manager.loadAndVerify(repoRoot: repo.repoURL)
    let signedHash = reg.rules["attack-rule-4"]
    #expect(signedHash != nil)

    // Attacker silently modifies rule.swift without Touch ID signature
    let ruleSwiftURL = repo.repoURL.appendingPathComponent("invariants/rules/attack-rule-4/rule.swift")
    try "// tampered code\n".write(to: ruleSwiftURL, atomically: true, encoding: .utf8)

    // Fingerprint engine computes new hash that drifts from signedHash
    let driftHash = try await FingerprintEngine().computeFingerprint(repoRoot: repo.repoURL, ruleId: "attack-rule-4")
    #expect(driftHash != signedHash)
  }

  @Test("Attack 5: Using an expired / soft-revoked key is rejected by OpenSSH date validation")
  func attack5_expiredKeyUsage() async throws {
    let repo = try await TestRepo()
    try repo.withRule("attack-rule-5")

    // Expire the key in allowed_signers with valid-before in the past
    let signersURL = RegistryManager.allowedSignersURL(repoRoot: repo.repoURL)
    let pubKeyStr = (try String(contentsOf: repo.pubKeyURL, encoding: .utf8)).trimmingCharacters(
      in: .whitespacesAndNewlines)
    let expiredSigners = "* namespaces=\"invariants\",valid-before=\"20200101000000\" \(pubKeyStr)\n"
    try expiredSigners.write(to: signersURL, atomically: true, encoding: .utf8)

    // Save and sign with the expired key
    let manager = RegistryManager(environment: repo.environment)
    let reg = Registry(version: 1, engine: "^1.0.0")
    try await manager.saveAndSign(registry: reg, repoRoot: repo.repoURL, keyURL: repo.keyURL)

    // loadAndVerify must reject with signatureInvalid (key expired)
    await #expect(throws: RegistryError.self) {
      _ = try await manager.loadAndVerify(repoRoot: repo.repoURL)
    }
  }
}
