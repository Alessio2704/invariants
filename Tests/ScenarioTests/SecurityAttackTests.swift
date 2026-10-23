import Foundation
import Testing

@testable import Core

@Suite("Engine Security & Attack Scenarios", .tags(.scenario), .tags(.security))
struct SecurityAttackTests {

  @Test("Attack 1: Rogue Agent injects public key into allowed_signers without re-signing")
  func attack1_unsignedSignersInjection() async throws {
    let repo = try await TestRepo()
    try repo.withRule("attack-rule-1")
    try await repo.signed(version: 1)

    // Attacker injects a rogue key into invariants/allowed_signers
    let signersURL = repo.run { RegistryManager.allowedSignersURL() }
    let rogueKey =
      "* namespaces=\"invariants\" ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBMockRogueKey rogue@attacker\n"
    var content = try signersURL.readUTF8()
    content.append(rogueKey)
    try content.write(to: signersURL, atomically: true, encoding: .utf8)

    // loadAndVerify must immediately detect that signers_hash does not match
    await #expect(throws: RegistryError.self) {
      try await repo.run {
        _ = try await RegistryManager.loadAndVerify()
      }
    }
  }

  @Test("Attack 2: Rogue Agent generates unauthorized key, replaces signers and registry, signs with rogue key")
  func attack2_unauthorizedKeyForgedRegistry() async throws {
    let repo = try await TestRepo()
    try repo.withRule("attack-rule-2")
    try await repo.signed(version: 1)

    // Attacker generates throwaway key
    let rogueKeyURL = repo.repoURL.appendingPathComponent("id_rogue")
    try SigningClient.generateThrowawayKey(at: rogueKeyURL)

    let roguePub = try repo.repoURL.appendingPathComponent("id_rogue.pub").readTrimmedUTF8()

    // Attacker appends rogue key to allowed_signers
    let signersURL = repo.run { RegistryManager.allowedSignersURL() }
    var signersContent = try signersURL.readUTF8()
    signersContent.append("* namespaces=\"invariants\" \(roguePub)\n")
    try signersContent.write(to: signersURL, atomically: true, encoding: .utf8)

    // Attacker creates version 2 registry and signs with rogueKey
    let reg2 = Registry.forTesting(version: 2, engine: "^1.0.0")
    try await repo.run {
      try await RegistryManager.saveAndSign(registry: reg2, keyURL: rogueKeyURL)

      // Ancestry verification must catch that rogueKey was not in parent commit's allowed_signers!
      await #expect(throws: FloorError.self) {
        try await FloorGuard.checkSignerAncestry(currentRegistry: reg2)
      }
    }
  }

  @Test("Attack 2b: Rogue agent commits forged registry.lock to git; ancestry check still catches it")
  func attack2b_committedRogueSigner() async throws {
    let repo = try await TestRepo()
    try repo.withRule("attack-rule-2b")
    try await repo.signed(version: 1)

    // Attacker generates rogue key, adds to allowed_signers, signs v2, AND COMMITS to git
    let rogueKeyURL = repo.repoURL.appendingPathComponent("id_rogue")
    try SigningClient.generateThrowawayKey(at: rogueKeyURL)
    let roguePub = try repo.repoURL.appendingPathComponent("id_rogue.pub").readTrimmedUTF8()

    let signersURL = repo.run { RegistryManager.allowedSignersURL() }
    var signersContent = try signersURL.readUTF8()
    signersContent.append("* namespaces=\"invariants\" \(roguePub)\n")
    try signersContent.write(to: signersURL, atomically: true, encoding: .utf8)

    let reg2 = Registry.forTesting(version: 2, engine: "^1.0.0")
    try await repo.run {
      try await RegistryManager.saveAndSign(registry: reg2, keyURL: rogueKeyURL)
      try await GitClient.commit(paths: ["."], message: "Rogue commit forged v2")

      // Ancestry verification must catch that rogueKey was not in parent commit's allowed_signers,
      // EVEN AFTER the rogue changes were committed to git!
      await #expect(throws: FloorError.self) {
        try await FloorGuard.checkSignerAncestry(currentRegistry: reg2)
      }
    }
  }

  @Test("Attack 3: Replay / Rollback attack resets registry.lock to an older version")
  func attack3_rollbackAttack() async throws {
    let repo = try await TestRepo()
    try repo.withRule("attack-rule-3")
    try await repo.signed(version: 1)
    try await repo.signed(version: 2)

    // Attacker attempts to revert working tree registry.lock to version 1
    let reg1 = Registry.forTesting(version: 1, engine: "^1.0.0")
    try await repo.run {
      try await RegistryManager.saveAndSign(registry: reg1, keyURL: repo.keyURL)

      // FloorGuard history check must reject version 1 because history max is 2
      await #expect(throws: FloorError.self) {
        _ = try await FloorGuard.checkHistory(currentVersion: 1)
      }
    }
  }

  @Test("Attack 4: Rule tampering / weakening causes fingerprint drift and fails check")
  func attack4_fingerprintDrift() async throws {
    let repo = try await TestRepo()
    try repo.withRule("attack-rule-4")
    try await repo.signed(version: 1)

    let reg = try await repo.run {
      try await RegistryManager.loadAndVerify()
    }
    let signedHash = reg.rules["attack-rule-4"]
    #expect(signedHash != nil)

    // Attacker silently modifies rule.swift without Touch ID signature
    let ruleSwiftURL = repo.repoURL.appendingPathComponent("invariants/rules/attack-rule-4/rule.swift")
    try "// tampered code\n".write(to: ruleSwiftURL, atomically: true, encoding: .utf8)

    // Fingerprint engine computes new hash that drifts from signedHash
    let driftHash = try await repo.run {
      try await FingerprintEngine.computeFingerprint(ruleId: "attack-rule-4")
    }
    #expect(driftHash != signedHash)
  }

  @Test("Attack 5: Using an expired / soft-revoked key is rejected by OpenSSH date validation")
  func attack5_expiredKeyUsage() async throws {
    let repo = try await TestRepo()
    try repo.withRule("attack-rule-5")

    // Expire the key in allowed_signers with valid-before in the past
    let signersURL = repo.run { RegistryManager.allowedSignersURL() }
    let pubKeyStr = try repo.pubKeyURL.readTrimmedUTF8()
    let expiredSigners = "* namespaces=\"invariants\",valid-before=\"20200101000000\" \(pubKeyStr)\n"
    try expiredSigners.write(to: signersURL, atomically: true, encoding: .utf8)

    // Save and sign with the expired key
    let reg = Registry.forTesting(version: 1, engine: "^1.0.0")
    try await repo.run {
      try await RegistryManager.saveAndSign(registry: reg, keyURL: repo.keyURL)

      // loadAndVerify must reject with signatureInvalid (key expired)
      await #expect(throws: RegistryError.self) {
        _ = try await RegistryManager.loadAndVerify()
      }
    }
  }
}
