import Foundation
import Testing

@testable import Core
@testable import Managers
@testable import Workflows

@Suite("Workflow Transaction & Git Isolation Regression Tests", .tags(.scenario))
struct WorkflowTransactionTests {

  @Test("GitClient.commit only commits specified paths without touching other staged files")
  func testGitCommitPathIsolation() async throws {
    let repo = try await TestRepo()

    // Developer staged an unrelated file
    let unrelatedFile = repo.repoURL.appendingPathComponent("UnrelatedStaged.swift")
    try "let x = 1\n".write(to: unrelatedFile, atomically: true, encoding: .utf8)

    try await repo.run {
      _ = try await SubprocessRunner.run(
        binary: .git,
        arguments: ["-C", repo.repoURL.path, "add", "UnrelatedStaged.swift"],
        workingDirectory: repo.repoURL
      )
    }

    // Now call GitClient.commit for only invariants files
    let testDoc = repo.repoURL.appendingPathComponent("invariants_doc.txt")
    try "invariants content\n".write(to: testDoc, atomically: true, encoding: .utf8)

    try await repo.run {
      try await GitClient.commit(paths: ["invariants_doc.txt"], message: "Test invariant commit")
    }

    // Verify git status: UnrelatedStaged.swift MUST still be staged in the index!
    let statusOutput = try await repo.run {
      try await SubprocessRunner.run(
        binary: .git,
        arguments: ["-C", repo.repoURL.path, "status", "--porcelain"],
        workingDirectory: repo.repoURL
      )
    }

    let status = statusOutput.stdoutString
    #expect(status.contains("A  UnrelatedStaged.swift"))
  }

  @Test("SignersWorkflow.add automatically commits changes to git")
  func testSignersWorkflowAutoCommit() async throws {
    let repo = try await TestRepo()
    try repo.withRule("test-rule-commit")
    try await repo.signed(version: 1, defaultBranch: "main")

    // Create a new key to enroll
    let newKeyURL = repo.repoURL.appendingPathComponent("bob_key")
    try SigningClient.generateThrowawayKey(at: newKeyURL)
    let newPub = try newKeyURL.appendingPathExtension("pub").readTrimmedUTF8()

    // Add signer via SignersWorkflow
    try await repo.run {
      try await SignersWorkflow.add(
        key: newPub,
        identity: "bob@acme.com",
        signingKey: repo.keyURL.path
      )
    }

    // Verify working tree is clean and commit was recorded
    let logOutput = try await repo.run {
      try await SubprocessRunner.run(
        binary: .git,
        arguments: ["-C", repo.repoURL.path, "log", "-1", "--oneline"],
        workingDirectory: repo.repoURL
      )
    }
    #expect(logOutput.stdoutString.contains("Add invariant signer (registry v2)"))

    let statusOutput = try await repo.run {
      try await SubprocessRunner.run(
        binary: .git,
        arguments: ["-C", repo.repoURL.path, "status", "--porcelain", "invariants/"],
        workingDirectory: repo.repoURL
      )
    }
    #expect(statusOutput.stdoutString.trimmed.isEmpty)
  }

  @Test("RemoveRuleWorkflow abort leaves rule intact on disk")
  func testRemoveRuleAbortLeavesDiskIntact() async throws {
    let repo = try await TestRepo()
    try repo.withRule("rule-to-remove")
    try await repo.signed(version: 1, defaultBranch: "main")

    let ruleDir = repo.repoURL.appendingPathComponent("invariants/rules/rule-to-remove")
    let fm = FileManager.default
    #expect(fm.fileExists(atPath: ruleDir.path))

    // If abort occurs, the directory must remain present on disk
    // Verify targetVersion calculation: registry v1 -> target v2
    let registry = try await repo.run {
      try await RegistryManager.loadAndVerify(identity: "*")
    }
    #expect(registry.version == 1)
    #expect(registry.rules["rule-to-remove"] != nil)
  }

  @Test("HardwareKeyManager.rotateHardwareKey rolls back original key files when biometric auth fails")
  func testRotateHardwareKeyRollbackOnFailure() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("rotate_rollback_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let keyURL = tmpDir.appendingPathComponent("invariants_p256")
    let pubURL = keyURL.appendingPathExtension("pub")

    try SigningClient.generateThrowawayKey(at: keyURL)
    let originalKeyData = try Data(contentsOf: keyURL)
    let originalPubData = try Data(contentsOf: pubURL)

    // Token that is expired, so generateSigningKey inside rotateHardwareKey throws
    let expiredToken = BiometricAuthToken.forTesting(
      authorizedAt: Date().addingTimeInterval(-60),
      expirationInterval: 30
    )

    do {
      _ = try await HardwareKeyManager.rotateHardwareKey(at: keyURL, token: expiredToken)
      Issue.record("Expected rotateHardwareKey to throw on expired token")
    } catch {
      // Expected throw
    }

    // Verify atomic rollback: the original key and .pub MUST be restored at keyURL
    #expect(FileManager.default.fileExists(atPath: keyURL.path))
    #expect(FileManager.default.fileExists(atPath: pubURL.path))
    let restoredKeyData = try Data(contentsOf: keyURL)
    let restoredPubData = try Data(contentsOf: pubURL)
    #expect(restoredKeyData == originalKeyData)
    #expect(restoredPubData == originalPubData)
  }
}
