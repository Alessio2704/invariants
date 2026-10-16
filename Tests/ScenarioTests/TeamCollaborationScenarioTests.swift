import Foundation
import Testing

@testable import InvariantCore

@Suite("Team Collaboration & Key Lifecycle Scenarios", .tags(.scenario))
struct TeamCollaborationScenarioTests {

  @Test("Scenario A: Fresh Junior developer onboards, verifies rules cleanly without a signing key")
  func scenarioA_juniorOnboarding() async throws {
    let repo = try await TestRepo()
    try repo.withRule("team-rule-1")
    try await repo.signed(version: 1)

    // Junior has no signing key, but can load and verify rules immediately
    let manager = RegistryManager(environment: repo.environment)
    let registry = try await manager.loadAndVerify(repoRoot: repo.repoURL)
    #expect(registry.version == 1)
    #expect(registry.rules["team-rule-1"] != nil)

    let floorGuard = FloorGuard()
    let histFloor = try await floorGuard.checkHistory(repoRoot: repo.repoURL, currentVersion: registry.version)
    #expect(histFloor == 1)

    // Junior writes application code in Sources/App/
    let appFile = repo.repoURL.appendingPathComponent("Sources/App/main.swift")
    try FileManager.default.createDirectory(at: appFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "print(\"Hello Team!\")\n".write(to: appFile, atomically: true, encoding: .utf8)

    // Junior verifies rules again before commit: still 100% passes!
    let verified = try await manager.loadAndVerify(repoRoot: repo.repoURL)
    #expect(verified.version == 1)
  }

  @Test("Scenario B: Authority delegation — Senior authorizes Junior, Junior can then add rules")
  func scenarioB_authorityDelegation() async throws {
    let repo = try await TestRepo()
    try repo.withRule("team-rule-2")
    try await repo.signed(version: 1)

    let signingClient = SigningClient()
    let juniorKeyURL = repo.repoURL.appendingPathComponent("id_junior")
    try signingClient.generateThrowawayKey(at: juniorKeyURL)

    let juniorPub = (try String(contentsOf: repo.repoURL.appendingPathComponent("id_junior.pub"), encoding: .utf8))
      .trimmingCharacters(in: .whitespacesAndNewlines)

    // Senior adds Junior's key to invariants/allowed_signers
    let signersURL = RegistryManager.allowedSignersURL(repoRoot: repo.repoURL)
    var signersContent = try String(contentsOf: signersURL, encoding: .utf8)
    signersContent.append("* namespaces=\"invariants\" \(juniorPub)\n")
    try signersContent.write(to: signersURL, atomically: true, encoding: .utf8)

    // Senior bumps registry to v2 and signs with Senior's key
    let manager = RegistryManager(environment: repo.environment, signingClient: signingClient)
    let reg2 = Registry(version: 2, engine: "^1.0.0", rules: ["team-rule-2": "hash"])
    try await manager.saveAndSign(registry: reg2, repoRoot: repo.repoURL, keyURL: repo.keyURL)

    let gitClient = GitClient()
    try await gitClient.commit(
      repoRoot: repo.repoURL, paths: ["."], message: "Senior added Junior as authorized signer")

    // Now Junior adds a new rule and signs v3 with Junior's key!
    try repo.withRule("junior-rule-1")
    var reg3 = reg2
    reg3.version = 3
    reg3.rules["junior-rule-1"] = "hash-junior"
    try await manager.saveAndSign(registry: reg3, repoRoot: repo.repoURL, keyURL: juniorKeyURL)

    // 1. Working tree verification passes
    let verifiedV3 = try await manager.loadAndVerify(repoRoot: repo.repoURL)
    #expect(verifiedV3.version == 3)

    // 2. Ancestry check passes because Junior was in Commit 2's allowed_signers!
    let floorGuard = FloorGuard()
    let lockURL = RegistryManager.registryURL(repoRoot: repo.repoURL)
    let sigURL = RegistryManager.signatureURL(repoRoot: repo.repoURL)

    try await floorGuard.checkSignerAncestry(
      repoRoot: repo.repoURL,
      currentRegistry: reg3,
      lockURL: lockURL,
      sigURL: sigURL,
      signingClient: signingClient
    )
  }

  @Test("Scenario C: Routine key rotation — seamless transition and ongoing verification")
  func scenarioC_keyRotation() async throws {
    let repo = try await TestRepo()
    try repo.withRule("team-rule-3")
    try await repo.signed(version: 1)

    let signingClient = SigningClient()
    let seniorKeyV2 = repo.repoURL.appendingPathComponent("id_senior_v2")
    try signingClient.generateThrowawayKey(at: seniorKeyV2)

    let oldPub = (try String(contentsOf: repo.pubKeyURL, encoding: .utf8)).trimmingCharacters(
      in: .whitespacesAndNewlines)
    let newPub = (try String(contentsOf: repo.repoURL.appendingPathComponent("id_senior_v2.pub"), encoding: .utf8))
      .trimmingCharacters(in: .whitespacesAndNewlines)

    // Senior rotates: marks old valid-before in 24 hours, adds new valid-after
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMddHHmmss"
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    let validBeforeTs = formatter.string(from: Date().addingTimeInterval(86400))
    let validAfterTs = formatter.string(from: Date())

    let signersURL = RegistryManager.allowedSignersURL(repoRoot: repo.repoURL)
    let rotatedSigners = """
      * namespaces=\"invariants\",valid-before=\"\(validBeforeTs)\" \(oldPub)
      * namespaces=\"invariants\",valid-after=\"\(validAfterTs)\" \(newPub)

      """
    try rotatedSigners.write(to: signersURL, atomically: true, encoding: .utf8)

    // Rotation transaction (v2) is signed with the old key to establish authority transition
    let manager = RegistryManager(environment: repo.environment, signingClient: signingClient)
    let reg2 = Registry(version: 2, engine: "^1.0.0", rules: ["team-rule-3": "hash"])
    try await manager.saveAndSign(registry: reg2, repoRoot: repo.repoURL, keyURL: repo.keyURL)

    let gitClient = GitClient()
    try await gitClient.commit(repoRoot: repo.repoURL, paths: ["."], message: "Rotated Senior signing key")

    // Verification on v2 passes cleanly
    let verifiedV2 = try await manager.loadAndVerify(repoRoot: repo.repoURL)
    #expect(verifiedV2.version == 2)

    // Subsequent operation (v3) uses the new key
    var reg3 = reg2
    reg3.version = 3
    try await manager.saveAndSign(registry: reg3, repoRoot: repo.repoURL, keyURL: seniorKeyV2)

    // Verification on v3 passes cleanly with new key
    let verifiedV3 = try await manager.loadAndVerify(repoRoot: repo.repoURL)
    #expect(verifiedV3.version == 3)

    let floorGuard = FloorGuard()
    let lockURL = RegistryManager.registryURL(repoRoot: repo.repoURL)
    let sigURL = RegistryManager.signatureURL(repoRoot: repo.repoURL)
    try await floorGuard.checkSignerAncestry(
      repoRoot: repo.repoURL,
      currentRegistry: reg3,
      lockURL: lockURL,
      sigURL: sigURL,
      signingClient: signingClient
    )
  }

  @Test("Scenario D: Compromised key revocation & full repository recovery")
  func scenarioD_revocationAndRecovery() async throws {
    let repo = try await TestRepo()
    try repo.withRule("team-rule-4")

    let signingClient = SigningClient()
    let seniorAKey = repo.keyURL
    let seniorBKey = repo.repoURL.appendingPathComponent("id_senior_b")
    try signingClient.generateThrowawayKey(at: seniorBKey)

    let pubA = (try String(contentsOf: repo.pubKeyURL, encoding: .utf8)).trimmingCharacters(
      in: .whitespacesAndNewlines)
    let pubB = (try String(contentsOf: repo.repoURL.appendingPathComponent("id_senior_b.pub"), encoding: .utf8))
      .trimmingCharacters(in: .whitespacesAndNewlines)

    // Initial signers has both Senior A and Senior B
    let signersURL = RegistryManager.allowedSignersURL(repoRoot: repo.repoURL)
    let initialSigners = "* namespaces=\"invariants\" \(pubA)\n* namespaces=\"invariants\" \(pubB)\n"
    try initialSigners.write(to: signersURL, atomically: true, encoding: .utf8)

    let manager = RegistryManager(environment: repo.environment, signingClient: signingClient)
    let reg1 = Registry(version: 1, engine: "^1.0.0", rules: ["team-rule-4": "hash"])
    try await manager.saveAndSign(registry: reg1, repoRoot: repo.repoURL, keyURL: seniorAKey)

    let gitClient = GitClient()
    try await gitClient.commit(repoRoot: repo.repoURL, paths: ["."], message: "Initial v1 with Senior A and Senior B")

    // Senior A's laptop is compromised! Senior B immediately revokes Senior A's key
    let recoveredSigners = "* namespaces=\"invariants\" \(pubB)\n"
    try recoveredSigners.write(to: signersURL, atomically: true, encoding: .utf8)

    // Senior B signs v2
    var reg2 = reg1
    reg2.version = 2
    try await manager.saveAndSign(registry: reg2, repoRoot: repo.repoURL, keyURL: seniorBKey)
    try await gitClient.commit(repoRoot: repo.repoURL, paths: ["."], message: "Revoked compromised Senior A key")

    // 1. Repo is NOT bricked: Senior B verifies and passes!
    let verifiedV2 = try await manager.loadAndVerify(repoRoot: repo.repoURL)
    #expect(verifiedV2.version == 2)

    // 2. Attacker using Senior A's key attempts to sign v3
    var reg3 = reg2
    reg3.version = 3
    let lockURL = RegistryManager.registryURL(repoRoot: repo.repoURL)
    let lockData = try #require(CanonicalJSON.serialize(reg3).data(using: .utf8))
    try lockData.write(to: lockURL)
    try await signingClient.sign(keyURL: seniorAKey, namespace: "invariants", fileURL: lockURL)

    // Verification must reject because Senior A was revoked in v2
    await #expect(throws: RegistryError.self) {
      _ = try await manager.loadAndVerify(repoRoot: repo.repoURL)
    }

    // 3. Senior B recovers repository and signs legitimate v3
    try await manager.saveAndSign(registry: reg3, repoRoot: repo.repoURL, keyURL: seniorBKey)
    let verifiedV3 = try await manager.loadAndVerify(repoRoot: repo.repoURL)
    #expect(verifiedV3.version == 3)
  }
}
