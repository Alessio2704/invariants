import Foundation
import Testing

@testable import Core
@testable import Managers
@testable import Workflows

@Suite("Key Decoupling & Multi-Repository Governance Scenarios", .tags(.scenario))
struct KeyDecouplingScenarioTests {

  @Test("Local hardware key rotation preserves repository cleanliness without side-effects")
  func localKeyRotationDoesNotMutateRepository() async throws {
    let repo = try await TestRepo()
    try repo.withRule("core-rule-1")
    try await repo.signed(version: 1)

    // Verify initial clean state within repo context
    let (initialLock, initialSigners) = try repo.run {
      (
        try Data(contentsOf: RegistryManager.registryURL()),
        try RegistryManager.allowedSignersURL().readUTF8()
      )
    }

    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("decouple_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let machineKey = tmpDir.appendingPathComponent("invariants_p256")
    try SigningClient.generateThrowawayKey(at: machineKey)

    // Simulate local machine key rotation (archive old to backup and generate fresh key)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMddHHmmss"
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    let ts = formatter.string(from: Date())
    let backupKey = tmpDir.appendingPathComponent("invariants_p256.bak-\(ts)")
    let backupPub = backupKey.appendingPathExtension("pub")
    try FileManager.default.moveItem(at: machineKey, to: backupKey)
    try FileManager.default.moveItem(at: machineKey.appendingPathExtension("pub"), to: backupPub)
    try SigningClient.generateThrowawayKey(at: machineKey)

    #expect(FileManager.default.fileExists(atPath: backupKey.path))
    #expect(FileManager.default.fileExists(atPath: machineKey.path))

    // Ensure repo files were NOT touched by local machine rotation
    try await repo.run {
      let currentLock = try Data(contentsOf: RegistryManager.registryURL())
      let currentSigners = try RegistryManager.allowedSignersURL().readUTF8()
      #expect(initialLock == currentLock)
      #expect(initialSigners == currentSigners)

      let gitStatus = try await SubprocessRunner.run(
        binary: .git, arguments: ["-C", repo.repoURL.path, "status", "--porcelain"])
      #expect(gitStatus.trimmedStdout.isEmpty)
    }
  }

  @Test("Independent multi-repo rotation: machine key rotates once, repos updated explicitly")
  func independentMultiRepoRotation() async throws {
    let repoA = try await TestRepo()
    try repoA.withRule("repo-a-rule")
    try await repoA.signed(version: 1)

    let repoB = try await TestRepo()
    try repoB.withRule("repo-b-rule")
    try await repoB.signed(version: 1)

    // Generate Senior's initial key and add to both repos
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("multirepo_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let seniorKey = tmpDir.appendingPathComponent("id_senior")
    try SigningClient.generateThrowawayKey(at: seniorKey)
    let seniorPub = try seniorKey.appendingPathExtension("pub").readTrimmedUTF8()

    // Add senior key to Repo A
    try await repoA.run {
      try SignersManager.addSigner(keyContent: seniorPub, principal: "*")
      try await SignersManager.bumpAndSignRegistry(keyURL: repoA.keyURL)
      try await GitClient.commit(paths: ["."], message: "Added Senior to Repo A")
    }

    // Add senior key to Repo B
    try await repoB.run {
      try SignersManager.addSigner(keyContent: seniorPub, principal: "*")
      try await SignersManager.bumpAndSignRegistry(keyURL: repoB.keyURL)
      try await GitClient.commit(paths: ["."], message: "Added Senior to Repo B")
    }

    // Senior rotates personal machine key ONCE (archive old to backup and generate fresh key)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMddHHmmss"
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    let ts = formatter.string(from: Date())
    let backupKey = tmpDir.appendingPathComponent("id_senior.bak-\(ts)")
    let backupPub = backupKey.appendingPathExtension("pub")
    try FileManager.default.moveItem(at: seniorKey, to: backupKey)
    try FileManager.default.moveItem(at: seniorKey.appendingPathExtension("pub"), to: backupPub)
    try SigningClient.generateThrowawayKey(at: seniorKey)
    let newSeniorPub = try seniorKey.appendingPathExtension("pub").readTrimmedUTF8()

    // Neither repo is modified yet
    try await repoA.run {
      let gitStatus = try await SubprocessRunner.run(
        binary: .git, arguments: ["-C", repoA.repoURL.path, "status", "--porcelain"])
      #expect(gitStatus.trimmedStdout.isEmpty)
    }
    try await repoB.run {
      let gitStatus = try await SubprocessRunner.run(
        binary: .git, arguments: ["-C", repoB.repoURL.path, "status", "--porcelain"])
      #expect(gitStatus.trimmedStdout.isEmpty)
    }

    // Now explicitly update Repo A
    try await repoA.run {
      try SignersManager.rotateSigner(oldKeyDataOrSubstring: seniorPub, newPublicKeyString: newSeniorPub)
      try await SignersManager.bumpAndSignRegistry(keyURL: backupKey)
      try await GitClient.commit(paths: ["."], message: "Rotated Senior key in Repo A")

      let verified = try await RegistryManager.loadAndVerify()
      #expect(verified.version == 3)
    }

    // Repo B still verifies on v2
    try await repoB.run {
      let verifiedB = try await RegistryManager.loadAndVerify()
      #expect(verifiedB.version == 2)
    }

    // Now explicitly update Repo B
    try await repoB.run {
      try SignersManager.rotateSigner(oldKeyDataOrSubstring: seniorPub, newPublicKeyString: newSeniorPub)
      try await SignersManager.bumpAndSignRegistry(keyURL: backupKey)
      try await GitClient.commit(paths: ["."], message: "Rotated Senior key in Repo B")

      let verified = try await RegistryManager.loadAndVerify()
      #expect(verified.version == 3)
    }
  }

  @Test("SignersWorkflow and SignersManager orchestrate add, rotate, and revoke")
  func signersWorkflowAndManagerOrchestration() async throws {
    let repo = try await TestRepo()
    try repo.withRule("sample-rule")
    try await repo.signed(version: 1)

    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("signers_wf_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let devKey = tmpDir.appendingPathComponent("id_dev")
    try SigningClient.generateThrowawayKey(at: devKey)
    let devPub = try devKey.appendingPathExtension("pub").readTrimmedUTF8()

    try await repo.run {
      // 1. Add signer via SignersManager
      try SignersManager.addSigner(keyContent: devPub, principal: "dev@company.com")
      try await SignersManager.bumpAndSignRegistry(keyURL: repo.keyURL)

      let signersAfterAdd = try SignersManager.loadSigners()
      #expect(signersAfterAdd.contains(where: { $0.matches(keyString: devPub) && $0.isActive() }))

      // 2. Rotate signer via SignersManager
      let devKeyV2 = tmpDir.appendingPathComponent("id_dev_v2")
      try SigningClient.generateThrowawayKey(at: devKeyV2)
      let devPubV2 = try devKeyV2.appendingPathExtension("pub").readTrimmedUTF8()

      try SignersManager.rotateSigner(
        oldKeyDataOrSubstring: devPub,
        newPublicKeyString: devPubV2,
        sunsetDuration: 86400
      )
      try await SignersManager.bumpAndSignRegistry(keyURL: repo.keyURL)

      let signersAfterRotate = try SignersManager.loadSigners()
      let oldEntry = signersAfterRotate.first(where: { $0.matches(keyString: devPub) })
      let newEntry = signersAfterRotate.first(where: { $0.matches(keyString: devPubV2) })
      #expect(oldEntry?.validBefore != nil)
      #expect(newEntry?.isActive() == true)

      // 3. Revoke signer via SignersManager
      let revokedCount = try SignersManager.revokeSigner(matching: "dev@company.com", hard: true)
      #expect(revokedCount > 0)
      try await SignersManager.bumpAndSignRegistry(keyURL: repo.keyURL)

      let signersAfterRevoke = try SignersManager.loadSigners()
      #expect(!signersAfterRevoke.contains(where: { $0.principals.contains("dev@company.com") }))
    }
  }

  @Test("Mutating workflows fail fast immediately with SigningError when called with unauthorized key")
  func mutatingWorkflowsFailFastWithUnauthorizedKey() async throws {
    let repo = try await TestRepo()
    try repo.withRule("active-rule")
    try await repo.signed(version: 1)

    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("unauth_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    // Generate an outsider key NOT in allowed_signers
    let outsiderKey = tmpDir.appendingPathComponent("id_outsider")
    try SigningClient.generateThrowawayKey(at: outsiderKey)

    try await repo.run {
      // 1. AddRuleWorkflow fails fast
      await #expect(throws: SigningError.self) {
        try await AddRuleWorkflow.execute(ruleId: "new-rule", keyPath: outsiderKey.path)
      }

      // 2. RemoveRuleWorkflow fails fast
      await #expect(throws: SigningError.self) {
        try await RemoveRuleWorkflow.execute(ruleId: "active-rule", deleteFromDisk: false, keyPath: outsiderKey.path)
      }

      // 3. UpdateRuleWorkflow fails fast
      await #expect(throws: SigningError.self) {
        try await UpdateRuleWorkflow.execute(input: .init(id: "active-rule", keyPath: outsiderKey.path))
      }

      // 4. UpgradeWorkflow fails fast
      await #expect(throws: SigningError.self) {
        try await UpgradeWorkflow.execute(keyPath: outsiderKey.path)
      }

      // 5. ConfigWorkflow fails fast
      await #expect(throws: SigningError.self) {
        try await ConfigWorkflow.execute(languages: [.swift], defaultBranch: "main", keyPath: outsiderKey.path)
      }

      // 6. SignersWorkflow.add fails fast before modifying signers
      await #expect(throws: SigningError.self) {
        try await SignersWorkflow.add(
          key: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGtV+fakeKey", identity: "attacker", signingKey: outsiderKey.path)
      }

      // Verify repository files were NEVER touched
      let signersAfter = try SignersManager.loadSigners()
      #expect(!signersAfter.contains(where: { $0.principals.contains("attacker") }))
    }
  }
}
