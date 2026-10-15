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

    // Floor check passes
    let floorGuard = FloorGuard()
    let histFloor = try await floorGuard.checkHistory(repoRoot: repo.repoURL, currentVersion: loaded.version)
    #expect(histFloor == 1)
    let rootFloor = try floorGuard.checkRootFloor(
      repo: "test-happy", currentVersion: loaded.version, environment: repo.environment)
    #expect(rootFloor == 1)
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

    // Verify git archive extracts signed snapshot, NOT working tree
    let tempSnapshot = repo.repoURL.appendingPathComponent("temp_snapshot")
    try FileManager.default.createDirectory(at: tempSnapshot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempSnapshot) }

    try await GitClient().archiveExtract(repoRoot: repo.repoURL, treeHash: originalHash, destinationURL: tempSnapshot)
    let extractedContent = try String(contentsOf: tempSnapshot.appendingPathComponent("rule.swift"))
    #expect(!extractedContent.contains("mutated working tree"))
  }

  @Test("Security & tamper defenses: byte mutation and engine range mismatch")
  func tamperDefenses() async throws {
    let repo = try await TestRepo()
    try repo.withRule("toy", targets: [.swift])
    try await repo.signed(repo: "test-tamper", version: 1)

    let manager = RegistryManager(environment: repo.environment)

    // 1. Byte mutation in registry.lock
    let lockURL = RegistryManager.registryURL(repoRoot: repo.repoURL)
    var data = try Data(contentsOf: lockURL)
    data.append(Data("attacker_tamper".utf8))
    try data.write(to: lockURL)

    await #expect(throws: RegistryError.self) {
      _ = try await manager.loadAndVerify(repoRoot: repo.repoURL, installedEngineVersion: "1.0.0")
    }

    // 2. Engine range mismatch
    let repo2 = try await TestRepo()
    try repo2.withRule("toy2", targets: [.swift])
    let reg2 = Registry(repo: "test-range", version: 1, engine: "^2.0.0", rules: [:])
    let manager2 = RegistryManager(environment: repo2.environment)
    try await manager2.saveAndSign(registry: reg2, repoRoot: repo2.repoURL, keyURL: repo2.keyURL)

    await #expect(throws: RegistryError.engineVersionMismatch(required: "^2.0.0", installed: "1.0.0")) {
      _ = try await manager2.loadAndVerify(repoRoot: repo2.repoURL, installedEngineVersion: "1.0.0")
    }
  }

  @Test("Fixture harness accuracy: extra unexpected violations and missing expected violations")
  func fixtureHarnessAccuracy() async throws {
    let repo = try await TestRepo()
    try repo.withRule("accuracy", targets: [.swift])

    let discoverer = FixtureDiscoverer()
    let ruleDir = repo.repoURL.appendingPathComponent("invariants/rules/accuracy")
    let cases = try discoverer.discover(
      ruleDirectory: ruleDir,
      target: .swift,
      manifestCodes: ["TEST-01": "Test violation"]
    )

    let shouldFailCase = try #require(cases.first { !$0.isShouldPass })
    #expect(shouldFailCase.expectedViolations.count == 1)
    #expect(shouldFailCase.expectedViolations.first?.code == "TEST-01")

    let shouldPassCase = try #require(cases.first { $0.isShouldPass })
    #expect(shouldPassCase.expectedViolations.isEmpty)
  }

  @Test("Runtime safety error models: hung, crashed, stale index")
  func runtimeSafetyErrorModels() {
    let hung = RuleRunnerError.ruleHung(timeoutSeconds: 600)
    #expect(hung.errorDescription?.contains("timed out") == true)

    let crashed = RuleRunnerError.ruleCrashed(exitCode: 139, stderr: "Segmentation fault: 11")
    #expect(crashed.errorDescription?.contains("exit code 139") == true)

    let stale = RuleRunnerError.indexStale("Main.swift modified after index built")
    #expect(stale.errorDescription?.contains("INDEX STALE") == true)
  }

  @Test("Multi-failure aggregation: all rule issues surfaced in single report")
  func multiFailureAggregation() {
    let items: [RuleReportItem] = [
      RuleReportItem(
        ruleId: "rule-a",
        statusKind: .violations,
        violations: [
          ReportedViolation(code: "ERR-01", file: "A.swift", line: 10, column: 5, message: "Violation A", fix: "fix A")
        ]
      ),
      RuleReportItem(
        ruleId: "rule-b",
        statusKind: .modified,
        signedHash: "abc1234",
        currentHash: "def5678"
      ),
      RuleReportItem(
        ruleId: "rule-c",
        statusKind: .draft,
        draftPassedFixtures: 2,
        draftTotalFixtures: 2
      ),
    ]

    let report = CheckReport(registryVersion: 5, engineVersion: "1.0.0", rules: items)
    #expect(report.hasProblems == true)

    let textOutput = ReportFormatter.formatText(report)
    #expect(textOutput.contains("rule-a"))
    #expect(textOutput.contains("ERR-01"))
    #expect(textOutput.contains("rule-b"))
    #expect(textOutput.contains("modified"))
    #expect(textOutput.contains("rule-c"))
    #expect(textOutput.contains("draft"))

    let jsonOutput = ReportFormatter.formatJSON(report)
    #expect(jsonOutput.contains("\"ruleId\" : \"rule-a\"") || jsonOutput.contains("\"ruleId\": \"rule-a\""))
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
