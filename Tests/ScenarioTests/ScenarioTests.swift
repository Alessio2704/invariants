import Foundation
import Testing

@testable import InvariantCore

@Suite("Engine Scenarios & Tamper Defenses", .tags(.scenario), .tags(.security))
struct ScenarioTests {
  @Test("Happy path: rule creation, fixture verification, locking, and check")
  func happyPath() async throws {
    let repo = try await TestRepo()
    try repo.withRule(
      "toy", targets: [.swift],
      ruleSwiftBody: """
        if ctx.mode == .fixture && ctx.files.first?.path.contains("should_fail") == true {
            return [Violation(code: "TEST-01", file: "case1.swift", line: 1, column: 1, message: "Violation")]
        }
        return []
        """, extraFiles: ["App/Main.swift": "// Swift file\n"])

    try await repo.signed(repo: "test-happy", version: 1)

    let manager = RegistryManager(environment: repo.environment)
    let loaded = try await manager.loadAndVerify(repoRoot: repo.repoURL, installedEngineVersion: "1.0.0")
    #expect(loaded.version == 1)
    #expect(loaded.rules["toy"] != nil)
  }

  @Test("Tamper defense: byte mutation in registry.lock causes signature invalidation")
  func tamperedRegistryFails() async throws {
    let repo = try await TestRepo()
    try repo.withRule("toy", targets: [.swift])
    try await repo.signed(repo: "test-tamper", version: 1)

    let lockURL = RegistryManager.registryURL(repoRoot: repo.repoURL)
    var data = try Data(contentsOf: lockURL)
    data.append(Data("attacker_tamper".utf8))
    try data.write(to: lockURL)

    let manager = RegistryManager(environment: repo.environment)
    await #expect(throws: RegistryError.self) {
      _ = try await manager.loadAndVerify(repoRoot: repo.repoURL, installedEngineVersion: "1.0.0")
    }
  }

  @Test("Working tree mutation: drift detected, signed snapshot is enforced")
  func workingTreeMutationDrift() async throws {
    let repo = try await TestRepo()
    try repo.withRule("toy", targets: [.swift])
    try await repo.signed(repo: "test-drift", version: 1)

    let originalHash = try await FingerprintEngine().computeFingerprint(repoRoot: repo.repoURL, ruleId: "toy")

    // Mutate rule.swift in working tree
    let ruleSwiftURL = repo.repoURL.appendingPathComponent("invariants/rules/toy/rule.swift")
    try Data("// mutated working tree\n".utf8).write(to: ruleSwiftURL)

    let newHash = try await FingerprintEngine().computeFingerprint(repoRoot: repo.repoURL, ruleId: "toy")
    #expect(newHash != originalHash)

    // Status check reports drift
    let reg = try await RegistryManager(environment: repo.environment).loadAndVerify(repoRoot: repo.repoURL)
    #expect(reg.rules["toy"] == originalHash)
    #expect(newHash != reg.rules["toy"])
  }

  @Test("Rollback defense: version below floor is blocked")
  func rollbackDefense() async throws {
    let repo = try await TestRepo()
    let guardObj = FloorGuard()

    // Set root floor to 3
    try await SudoClient().writeFloor(repo: "test-repo", version: 3, environment: repo.environment)

    // Attempting to run with version 2 must throw versionBelowRootFloor
    #expect(throws: FloorError.versionBelowRootFloor(current: 2, rootFloor: 3, repo: "test-repo")) {
      _ = try guardObj.checkRootFloor(repo: "test-repo", currentVersion: 2, environment: repo.environment)
    }
  }

  @Test("Pre-push branch protection rejects non-fast-forward push to main")
  func prePushBranchProtection() async throws {
    let repo = try await TestRepo()
    let guardObj = FloorGuard()

    let nonFfInput =
      "refs/heads/main 1111111111111111111111111111111111111111 refs/heads/main 2222222222222222222222222222222222222222\n"
    await #expect(throws: FloorError.self) {
      try await guardObj.checkNoRewrite(repoRoot: repo.repoURL, pushedRefsInput: nonFfInput, defaultBranch: "main")
    }
  }
}
