import Foundation
import Testing

@testable import Core
@testable import Workflows

@Suite("Floor Ancestry & Historical Cryptographic Regression Tests", .tags(.scenario), .tags(.security))
struct FloorAncestryRegressionTests {

  @Test("FloorGuard ancestry check does not fail when historical commit was signed by a key that subsequently expired")
  func testAncestryWithSunsetExpiredHistoricalKey() async throws {
    let repo = try await TestRepo()
    try repo.withRule("test-rule-sunset")
    try await repo.signed(version: 1, defaultBranch: "main")

    // Key A created version 1.
    // Now create a second key (Key B).
    let keyB_URL = repo.repoURL.appendingPathComponent("keyB")
    try SigningClient.generateThrowawayKey(at: keyB_URL)
    let keyB_Pub = try keyB_URL.appendingPathExtension("pub").readTrimmedUTF8()

    // Add Key B to allowed_signers and mark Key A (the original owner key) as expired in 2020 (in the past)
    let signersURL = repo.run { RegistryManager.allowedSignersURL() }
    let ownerPub = try repo.pubKeyURL.readTrimmedUTF8()
    let updatedSigners = """
      * namespaces="invariants",valid-before="20200101000000" \(ownerPub)
      * namespaces="invariants" \(keyB_Pub)

      """
    try updatedSigners.write(to: signersURL, atomically: true, encoding: .utf8)

    // Commit 2: Signed by Key A (current authorized signer), enrolling Key B and setting valid-before on Key A
    try await repo.run {
      let lockURL = RegistryManager.registryURL()
      let data = try Data(contentsOf: lockURL)
      var reg = try CanonicalJSON.parse(data: data)
      reg.version = 2
      try await RegistryManager.saveAndSign(registry: reg, keyURL: repo.keyURL)
      try await GitClient.commit(
        paths: [
          "invariants/allowed_signers",
          "invariants/registry.lock",
          "invariants/registry.lock.sig",
        ],
        message: "Enroll Key B and sunset Key A (registry v2)"
      )
    }

    // Commit 3: Signed by Key B (now authorized in Commit 2's allowed_signers)
    try await repo.run {
      let lockURL = RegistryManager.registryURL()
      let data = try Data(contentsOf: lockURL)
      var reg = try CanonicalJSON.parse(data: data)
      reg.version = 3
      try await RegistryManager.saveAndSign(registry: reg, keyURL: keyB_URL)
      try await GitClient.commit(
        paths: [
          "invariants/registry.lock",
          "invariants/registry.lock.sig",
        ],
        message: "Sign version 3 with new Key B (registry v3)"
      )
    }

    // Now verify ancestry across commits 1, 2, and 3:
    // Commit 2 was signed by Key A (which has valid-before in 2020 in Commit 2's signers).
    // Because checkSignerAncestry evaluates against historical commit timestamp,
    // the ancestry walk must succeed without failing on expired keys!
    try await repo.run {
      let currentReg = try await RegistryManager.loadAndVerify(identity: "*")
      #expect(currentReg.version == 3)
      _ = try await FloorGuard.checkSignerAncestry(currentRegistry: currentReg)
    }
  }

  @Test("GitClient isShallowRepository detects repository clone depth")
  func testShallowRepositoryDetection() async throws {
    let repo = try await TestRepo()
    let isShallow = await repo.run {
      await GitClient.isShallowRepository()
    }
    // A fresh local git repo created by git init is not shallow
    #expect(isShallow == false)
  }
}
