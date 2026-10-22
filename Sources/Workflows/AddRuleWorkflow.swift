import Core
import Foundation
import Terminal

/// Interactive CLI workflow to lock and activate a draft rule into the signed registry.
package enum AddRuleWorkflow {
  package static func execute(ruleId: String, keyPath: String?) async throws {
    let repoRootURL = RepoLocator.current
    let env = SystemEnvironment.standard
    let runner = RuleRunner(environment: env)

    // 1. Authorize signing session upfront (fail-fast)
    let session = try SigningSession.authorize(customPath: keyPath)

    // 2. Load registry
    var registry = try await RegistryManager.loadAndVerify(
      installedEngineVersion: EngineVersion.current
    )

    guard registry.rules[ruleId] == nil else {
      throw AddRuleWorkflowError.alreadyActive(ruleId)
    }

    let ruleDir = repoRootURL.appendingPathComponent("invariants/rules/\(ruleId)")
    let fm = FileManager.default
    guard fm.fileExists(atPath: ruleDir.path) else {
      throw AddRuleWorkflowError.ruleDirectoryNotFound(ruleDir.path)
    }

    // 3. Validate manifest and structure
    let manifest = try ManifestParser.load(from: ruleDir.appendingPathComponent("manifest.json"), expectedId: ruleId)
    try ManifestValidator.validateStructure(
      ruleDirectory: ruleDir,
      manifest: manifest,
      registry: registry,
      isFixtureMode: false
    )

    // 4. Self-test fixtures
    Terminal.info("Running fixture self-test for '\(ruleId)'...")
    for target in manifest.targets {
      let cases = try FixtureDiscoverer.discover(
        ruleDirectory: ruleDir,
        target: target,
        manifestCodes: manifest.codes
      )
      for fixtureCase in cases {
        let req = RuleRequest(
          mode: "fixture",
          repoRoot: fixtureCase.rootURL.path,
          ruleDir: ruleDir.path,
          files: fixtureCase.files.map { $0.path },
          languages: registry.languages
        )
        let violations = try await runner.execute(
          target: target,
          ruleDirectory: ruleDir,
          ruleTreeHash: "add_preview",
          request: req,
          engineVersion: EngineVersion.current
        )

        let expected = Set(fixtureCase.expectedViolations)
        let reported = Set(
          violations.map {
            ExpectedViolation(
              relativePath: URL(fileURLWithPath: $0.file).lastPathComponent,
              line: $0.line,
              code: $0.code
            )
          })

        if fixtureCase.isShouldPass && !violations.isEmpty {
          throw AddRuleWorkflowError.fixtureFailed(
            "Fixture '\(fixtureCase.id)' failed: expected 0 violations, got \(violations.count)"
          )
        } else if !fixtureCase.isShouldPass && expected != reported {
          throw AddRuleWorkflowError.fixtureFailed("Fixture '\(fixtureCase.id)' expectation mismatch")
        }
      }
    }
    Terminal.success("All fixtures passed.")

    // 5. Repo impact preview
    var repoViolationsCount = 0
    for target in manifest.targets {
      guard let targetScope = manifest.scope[target] else { continue }
      let files = ManifestValidator.resolveScopedFiles(scope: targetScope, target: target)
      let req = RuleRequest(
        mode: "repo",
        repoRoot: repoRootURL.path,
        ruleDir: ruleDir.path,
        files: files.map { $0.path },
        languages: registry.languages
      )
      let violations = try await runner.execute(
        target: target,
        ruleDirectory: ruleDir,
        ruleTreeHash: "add_preview",
        request: req,
        engineVersion: EngineVersion.current
      )
      repoViolationsCount += violations.count
    }
    Terminal.info("Repo impact preview: \(repoViolationsCount) violations on current codebase.")

    let confirm = try TerminalPrompt.promptConfirmation(
      question: "Add and lock invariant '\(ruleId)' into registry v\(registry.version + 1)?",
      default: true
    )
    guard confirm else {
      Terminal.info("Aborted.")
      return
    }

    // 6. Compute tree hash
    let treeHash = try await FingerprintEngine.computeFingerprint(ruleId: ruleId)
    Terminal.field("Fingerprint:", value: treeHash)

    // 7. Update registry
    registry.version += 1
    registry.rules[ruleId] = treeHash

    Terminal.info("Signing registry v\(registry.version) with key \(session.privateKeyURL.lastPathComponent)...")
    try await RegistryManager.saveAndSign(
      registry: registry,
      keyURL: session.privateKeyURL
    )

    // 8. Commit
    try await GitClient.commit(
      paths: [
        "invariants/registry.lock",
        "invariants/registry.lock.sig",
        "invariants/rules/\(ruleId)",
      ],
      message: "Add invariant '\(ruleId)' (registry v\(registry.version))"
    )

    Terminal.success("Rule '\(ruleId)' activated and locked in registry v\(registry.version).")
  }
}

package enum AddRuleWorkflowError: LocalizedError, Sendable {
  case alreadyActive(String)
  case ruleDirectoryNotFound(String)
  case fixtureFailed(String)

  package var errorDescription: String? {
    switch self {
    case .alreadyActive(let id):
      return "Rule '\(id)' is already active in registry. Use 'invariants update \(id)' instead."
    case .ruleDirectoryNotFound(let path):
      return "Rule folder not found at \(path)"
    case .fixtureFailed(let reason):
      return reason
    }
  }
}
