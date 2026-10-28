import Foundation
import Testing

@testable import Core
@testable import Managers
@testable import Terminal
@testable import Workflows

@Suite("Security Attacks: Weakening, Path Traversal & Signer Parsing", .serialized, .tags(.securityAttack))
struct PolicyAndFilesystemAttackTests {

  @Test("SEC-06a: UpdateRuleWorkflow silently swallows runner errors with try? ?? [] and approves broken rule")
  func sec06a_updateRuleSwallowsRunnerErrorAndApprovesBrokenRule() async throws {
    let fixture = try await AuditProjectFixture()
    try await fixture.verifyBaseline()

    // Craft a Swift rule that passes its fixtures (so verifyFixtures succeeds)
    // but crashes / throws an error during repo-mode evaluation
    let ruleSwiftURL = fixture.repoURL.appendingPathComponent("invariants/rules/no-print-in-app/rule.swift")
    let brokenRuleSrc = """
      import InvariantKit

      @main
      struct NoPrintInAppRule: SwiftRule {
          func check(_ ctx: RuleContext) throws(RuleError) -> [Violation] {
              if ctx.mode == .repo {
                  throw RuleError.evaluationError("CRASH: Broken rule threw runtime error in repo mode")
              }
              let sources = SourceFileCollection(files: ctx.files, repoRoot: ctx.repoRoot)
              return sources.calls(named: "print").violations(
                  code: "NO-PRINT",
                  message: { _ in "print forbidden" },
                  fix: "Clean"
              )
          }
      }
      """
    try brokenRuleSrc.write(to: ruleSwiftURL, atomically: true, encoding: .utf8)

    // UpdateRuleWorkflow.collectRepoViolations:
    // let newViolations = (try? await runner.execute(request: newReq, ...)) ?? []
    // Because of try? ?? [], the thrown error is turned into [] (0 violations).
    // The workflow treats 0 violations as success and signs the broken rule!
    await #expect(
      throws: (any Error).self,
      "Vulnerability SEC-06a confirmed: UpdateRuleWorkflow swallowed runner failure and signed broken rule!"
    ) {
      try await fixture.run {
        try await UpdateRuleWorkflow.execute(
          input: .init(id: "no-print-in-app", keyPath: fixture.ownerKey.path)
        )
      }
    }
  }

  @Test("SEC-06b: ConfigWorkflow silently swallows runner errors with try? ?? [] and signs blinded config")
  func sec06b_configWorkflowSwallowsRunnerErrorAndApprovesBrokenConfig() async throws {
    let fixture = try await AuditProjectFixture()
    try await fixture.verifyBaseline()

    // Break no-print-in-app so that it throws when executed
    let ruleSwiftURL = fixture.repoURL.appendingPathComponent("invariants/rules/no-print-in-app/rule.swift")
    let brokenRuleSrc = """
      import InvariantKit

      @main
      struct NoPrintInAppRule: SwiftRule {
          func check(_ ctx: RuleContext) throws(RuleError) -> [Violation] {
              throw RuleError.evaluationFailure("Engine configuration incompatible with rule")
          }
      }
      """
    try brokenRuleSrc.write(to: ruleSwiftURL, atomically: true, encoding: .utf8)

    // Commit broken rule and enroll in registry so ConfigWorkflow extracts it from git
    _ = try await SubprocessRunner.run(
      binary: .git,
      arguments: ["-C", fixture.repoURL.path, "commit", "-a", "-m", "Commit broken rule"]
    )
    let brokenHash = try await fixture.run {
      try await FingerprintEngine.computeFingerprint(ruleId: "no-print-in-app")
    }
    var reg = try await fixture.run { try await RegistryManager.loadAndVerify() }
    reg.rules["no-print-in-app"] = brokenHash
    reg.version += 1
    try await fixture.run {
      try await RegistryManager.saveAndSign(registry: reg, keyURL: fixture.ownerKey)
      try await GitClient.commit(paths: ["invariants"], message: "Sign broken rule in registry")
    }

    // In ConfigWorkflow.swift:124-138:
    // With runner errors propagated, executing the broken rule throws and aborts ConfigWorkflow
    await #expect(
      throws: (any Error).self,
      "Vulnerability SEC-06b confirmed: ConfigWorkflow swallowed runner failure and signed invalid config!"
    ) {
      try await fixture.run {
        try await Terminal.withInteractiveSession {
          try await ConfigWorkflow.execute(
            languages: [.swift, .ts],
            defaultBranch: "main",
            keyPath: fixture.ownerKey.path
          )
        }
      }
    }
  }

  @Test("SEC-06c: UpdateRuleWorkflow resolves files from newManifest.scope for both old and new checks")
  func sec06c_updateRuleScopeNarrowingHidesDroppedRepoViolations() async throws {
    let fixture = try await AuditProjectFixture()
    try await fixture.verifyBaseline()

    // 1. Introduce a print() call in Network.swift (which is currently in scope for no-print-in-app)
    let networkSwiftURL = fixture.repoURL.appendingPathComponent("Sources/App/Network.swift")
    try "public struct NetworkService { public func fetch() { print(\"debug leak\") } }\n".write(
      to: networkSwiftURL, atomically: true, encoding: .utf8)

    // 2. Attacker narrows no-print-in-app scope to exclude Sources/App/Network.swift
    let manifestURL = fixture.repoURL.appendingPathComponent("invariants/rules/no-print-in-app/manifest.json")
    let tamperedManifest: [String: Any] = [
      "id": "no-print-in-app",
      "summary": "Narrowed scope to hide Network.swift leak",
      "targets": ["swift"],
      "scope": [
        "swift": [
          "include": ["Sources/**/*.swift"],
          "exclude": ["Sources/App/Network.swift"],
        ]
      ],
      "codes": ["NO-PRINT": "print is forbidden"],
    ]
    let manifestData = try JSONSerialization.data(
      withJSONObject: tamperedManifest, options: [.prettyPrinted, .sortedKeys])
    try manifestData.write(to: manifestURL)

    // In UpdateRuleWorkflow.swift:185-200:
    // It iterates `context.newManifest.targets` and reads `context.newManifest.scope[target]`
    // to resolve files for BOTH oldReq and newReq!
    // Because Network.swift is excluded from newManifest.scope, oldReq is never run on Network.swift.
    // Thus oldViolations.count == 0, newViolations.count == 0, and dropped repo violations == 0!
    // When UpdateRuleWorkflow evaluates old rule against oldManifest.scope, it detects
    // that the existing violation in Network.swift was dropped, flagging red weakening and blocking unconfirmed update.
    await #expect(
      throws: (any Error).self,
      "Vulnerability SEC-06c confirmed: UpdateRuleWorkflow failed to detect dropped repo violation when scope was narrowed!"
    ) {
      try await fixture.run {
        try await UpdateRuleWorkflow.execute(
          input: .init(id: "no-print-in-app", keyPath: fixture.ownerKey.path)
        )
      }
    }
  }

  @Test("SEC-07a: RuleScaffoldManager permits ruleId with path traversal (../) escaping rules directory")
  func sec07a_manifestAndScaffoldRuleIdPathTraversal() async throws {
    let fixture = try await AuditProjectFixture()
    let escapedRuleId = "../escaped_rule_\(UUID().uuidString)"
    let escapedDir = fixture.repoURL.appendingPathComponent("invariants").appendingPathComponent(
      escapedRuleId.replacingOccurrences(of: "../", with: "")
    )

    // RuleScaffoldManager does not validate ruleId against schema pattern ^[a-z0-9]+(-[a-z0-9]+)*$
    // It creates invariants/rules/../escaped_rule = invariants/escaped_rule
    #expect(
      throws: (any Error).self,
      "Vulnerability SEC-07a confirmed: RuleScaffoldManager permitted path traversal in ruleId!"
    ) {
      try RuleScaffoldManager.scaffoldRule(id: escapedRuleId, targets: [.swift], in: fixture.repoURL)
    }

    #expect(
      !FileManager.default.fileExists(atPath: escapedDir.path),
      "Vulnerability SEC-07a confirmed: files were created outside invariants/rules/ via path traversal!"
    )
  }

  @Test("SEC-07b: RemoveRuleWorkflow deletes directory outside invariants/rules via path traversal ruleId")
  func sec07b_removeRulePathTraversalDeletesOutsideDirectory() async throws {
    let fixture = try await AuditProjectFixture()

    // Create a target directory outside invariants/rules/
    let outsideDir = fixture.repoURL.appendingPathComponent("invariants/precious_data")
    try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
    try "critical".write(to: outsideDir.appendingPathComponent("data.txt"), atomically: true, encoding: .utf8)

    #expect(FileManager.default.fileExists(atPath: outsideDir.path))

    // Enroll "../precious_data" into registry.lock so it passes the registry membership check
    var reg = try await fixture.run {
      try await RegistryManager.loadAndVerify()
    }
    reg.rules["../precious_data"] = "0000000000000000000000000000000000000000"
    reg.version += 1
    let regURL = fixture.repoURL.appendingPathComponent("invariants/registry.lock")
    try CanonicalJSON.serialize(reg).write(to: regURL, atomically: true, encoding: .utf8)
    _ = try await SigningClient.sign(keyURL: fixture.ownerKey, fileURL: regURL)

    // RemoveRuleWorkflow does:
    // let ruleDir = root.appendingPathComponent("invariants/rules/\(ruleId)")
    // try fm.removeItem(at: ruleDir)
    // When ruleId is "../precious_data", it deletes invariants/rules/../precious_data = invariants/precious_data!
    _ = try? await fixture.run {
      try await Terminal.withInteractiveSession {
        try await RemoveRuleWorkflow.execute(
          ruleId: "../precious_data",
          deleteFromDisk: true,
          keyPath: fixture.ownerKey.path
        )
      }
    }

    // Secure invariant: Directory outside invariants/rules/ must NOT be deleted via path traversal ruleId!
    #expect(
      FileManager.default.fileExists(atPath: outsideDir.path),
      "Vulnerability SEC-07b confirmed: directory outside invariants/rules/ was deleted via path traversal!"
    )
  }

  @Test("SEC-08a: AllowedSignersFile.revoke matches short Base64 substring, revoking all team signers")
  func sec08a_revokeShortSubstringWipesUnrelatedTeamSigners() async throws {
    let fixture = try await AuditProjectFixture()

    // Enroll Coworker and Contractor
    let signersURL = fixture.repoURL.appendingPathComponent("invariants/allowed_signers")
    var content = try signersURL.readUTF8()
    content.append("* namespaces=\"invariants\" \(fixture.coworkerPub) coworker@acme.com\n")
    content.append("* namespaces=\"invariants\" \(fixture.contractorPub) contractor@acme.com\n")
    try content.write(to: signersURL, atomically: true, encoding: .utf8)

    var file = try AllowedSignersFile.read(from: signersURL)
    #expect(file.entries.count == 3)

    // Every ECDSA P-256 public key starts with Base64 prefix "AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY"
    // AllowedSignersFile.revoke checks:
    // entries[i].keyData.contains(keyDataOrSubstring)
    // Revoking with a 4-letter substring "AAAA" matches EVERY key's Base64 data!
    file.revoke(keyDataOrSubstring: "AAAA")

    let activeEntries = file.entries.filter { $0.validBefore == nil }

    // Secure behavior: Revoking a short substring like "AAAA" must not accidentally wipe all 3 team keys!
    #expect(
      activeEntries.count >= 2,
      "Vulnerability SEC-08a confirmed: revoking 'AAAA' wiped \(3 - activeEntries.count) team keys via Base64 match!"
    )
  }

  @Test("SEC-08b: AllowedSignersFile.addPublicKey preserves embedded newlines, allowing signer injection")
  func sec08b_addPublicKeyNewlineInjectionEnrollsRogueKey() async throws {
    let fixture = try await AuditProjectFixture()
    let signersURL = fixture.repoURL.appendingPathComponent("invariants/allowed_signers")
    var file = try AllowedSignersFile.read(from: signersURL)
    #expect(file.entries.count == 1)

    // Injected key string with embedded newline creating a rogue authorized signer
    let injectedKeyString = """
      ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBMockKey comment
      * namespaces="invariants" \(fixture.rogueAgentPub)
      """

    // Secure behavior: A single call to addPublicKey must NEVER enroll 2 signers via newline injection!
    #expect(
      throws: (any Error).self,
      "Vulnerability SEC-08b confirmed: addPublicKey permitted embedded newlines!"
    ) {
      try file.addPublicKey(injectedKeyString)
    }
  }
}
