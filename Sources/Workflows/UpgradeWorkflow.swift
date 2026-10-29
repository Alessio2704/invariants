import Core
import Foundation
import Terminal

/// Interactive CLI workflow to re-verify rules and upgrade engine range in registry.
package enum UpgradeWorkflow {
  package static func execute(keyPath: String?) async throws {
    let repoRootURL = RepoLocator.current
    let env = SystemEnvironment.standard
    let runner = RuleRunner(environment: env)

    // 1. Authorize signing session upfront (fail-fast)
    let session = try SigningSession.authorize(customPath: keyPath)

    // 2. Load and verify registry (allow engine mismatch so new major versions can upgrade the lockfile)
    var registry = try await RegistryManager.loadAndVerify(
      allowEngineMismatch: true
    )

    let newRange = EngineVersion.defaultRange
    Terminal.info("Re-verifying all active rules under engine \(EngineVersion.current)...")

    for (ruleId, signedTreeHash) in registry.rules.sorted(by: { $0.key < $1.key }) {
      try await RuleSnapshotService.withSnapshot(treeHash: signedTreeHash) { tempSnapshot, manifest in
        // Test fixtures (strictly enforcing should_pass and should_fail)
        do {
          try await FixtureExecutionService.verifyAllFixtures(
            manifest: manifest,
            ruleDirectory: tempSnapshot,
            ruleTreeHash: signedTreeHash,
            ast: registry.ast,
            runner: runner
          )
        } catch {
          throw UpgradeWorkflowError.fixtureFailed(ruleId)
        }

        // Check repo scope
        for target in manifest.targets {
          guard let targetScopes = manifest.scope[target] else { continue }
          let unitFilesURLs = ManifestValidator.resolveScopedFilesByUnit(scopes: targetScopes, target: target)
          var unitFiles: [String: [String]] = [:]
          var allFiles: [String] = []
          for (unit, urls) in unitFilesURLs {
            let paths = urls.map(\.path)
            unitFiles[unit] = paths
            allFiles.append(contentsOf: paths)
          }
          var seen = Set<String>()
          let dedupedFiles = allFiles.filter { seen.insert($0).inserted }

          let req = RuleRequest(
            mode: "repo",
            repoRoot: repoRootURL.path,
            ruleDir: tempSnapshot.path,
            files: dedupedFiles,
            unitFiles: unitFiles,
            ast: registry.ast
          )
          _ = try await runner.execute(
            target: target,
            ruleDirectory: tempSnapshot,
            ruleTreeHash: signedTreeHash,
            request: req
          )
        }
      }
    }

    Terminal.success("All active rule fixtures and repo checks passed under \(EngineVersion.current).")

    let confirm = try TerminalPrompt.promptConfirmation(
      question: "Upgrade engine range from '\(registry.engine)' to '\(newRange)'?",
      default: true
    )
    if !confirm {
      Terminal.info("Aborted.")
      return
    }

    registry.engine = newRange
    registry.version += 1

    try await RegistryManager.saveAndSign(
      registry: registry,
      keyURL: session.privateKeyURL
    )

    try await GitClient.commit(
      paths: [
        "invariants/registry.lock",
        "invariants/registry.lock.sig",
      ],
      message: "Upgrade invariants engine range to \(newRange) (registry v\(registry.version))"
    )

    Terminal.success("Upgraded engine range to \(newRange) in registry v\(registry.version).")
  }
}

package enum UpgradeWorkflowError: LocalizedError, Sendable {
  case fixtureFailed(String)

  package var errorDescription: String? {
    switch self {
    case .fixtureFailed(let ruleId):
      return "Rule '\(ruleId)' fixture failed under engine \(EngineVersion.current)."
    }
  }
}
