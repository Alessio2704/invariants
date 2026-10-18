import Core
import Foundation
import Terminal

/// Interactive CLI workflow to re-verify rules and upgrade engine range in registry.
package enum UpgradeWorkflow {
  package static func execute(keyPath: String?) async throws {
    let repoRootURL = RepoLocator.current
    let env = SystemEnvironment.standard
    let runner = RuleRunner(environment: env)
    let fm = FileManager.default

    var registry = try await RegistryManager.loadAndVerify(
      installedEngineVersion: EngineVersion.current
    )

    let newRange = "^\(EngineVersion.current)"
    print("Re-verifying all active rules under engine \(EngineVersion.current)...")

    for (ruleId, signedTreeHash) in registry.rules.sorted(by: { $0.key < $1.key }) {
      let tempSnapshot = fm.temporaryDirectory.appendingPathComponent("upgrade_\(ruleId)_\(UUID().uuidString)")
      defer { try? fm.removeItem(at: tempSnapshot) }

      try fm.createDirectory(at: tempSnapshot, withIntermediateDirectories: true)
      try await GitClient.archiveExtract(
        treeHash: signedTreeHash,
        destinationURL: tempSnapshot
      )

      let manifest = try ManifestParser.load(
        from: tempSnapshot.appendingPathComponent("manifest.json"), expectedId: ruleId)

      // Test fixtures
      for target in manifest.targets {
        let cases = try FixtureDiscoverer.discover(
          ruleDirectory: tempSnapshot, target: target, manifestCodes: manifest.codes)
        for fixtureCase in cases {
          let req = RuleRequest(
            mode: "fixture",
            repoRoot: fixtureCase.rootURL.path,
            ruleDir: tempSnapshot.path,
            files: fixtureCase.files.map { $0.path },
            languages: registry.languages
          )
          let violations = try await runner.execute(
            target: target,
            ruleDirectory: tempSnapshot,
            ruleTreeHash: signedTreeHash,
            request: req,
            engineVersion: EngineVersion.current
          )
          if fixtureCase.isShouldPass && !violations.isEmpty {
            throw UpgradeWorkflowError.fixtureFailed(ruleId)
          }
        }
      }

      // Check repo scope
      for target in manifest.targets {
        guard let scope = manifest.scope[target] else { continue }
        let scopedFiles = ManifestValidator.resolveScopedFiles(scope: scope, target: target)
        let req = RuleRequest(
          mode: "repo",
          repoRoot: repoRootURL.path,
          ruleDir: tempSnapshot.path,
          files: scopedFiles.map { $0.path },
          languages: registry.languages
        )
        _ = try await runner.execute(
          target: target,
          ruleDirectory: tempSnapshot,
          ruleTreeHash: signedTreeHash,
          request: req,
          engineVersion: EngineVersion.current
        )
      }
    }

    print("✓ All active rule fixtures and repo checks passed under \(EngineVersion.current).")

    if TerminalPrompt.isInteractive {
      let confirm = TerminalPrompt.promptConfirmation(
        question: "Upgrade engine range from '\(registry.engine)' to '\(newRange)'?",
        default: true
      )
      if !confirm {
        print("Aborted.")
        return
      }
    }

    registry.engine = newRange
    registry.version += 1

    guard let keyURL = await SigningKeyWorkflow.resolveOrPrompt(customPath: keyPath) else {
      throw UpgradeWorkflowError.noSigningKey
    }

    try await RegistryManager.saveAndSign(
      registry: registry,
      keyURL: keyURL
    )

    try await GitClient.commit(
      paths: [
        "invariants/registry.lock",
        "invariants/registry.lock.sig",
      ],
      message: "Upgrade invariants engine range to \(newRange) (registry v\(registry.version))"
    )

    print("✓ Upgraded engine range to \(newRange) in registry v\(registry.version).")
  }
}

package enum UpgradeWorkflowError: LocalizedError, Sendable {
  case fixtureFailed(String)
  case noSigningKey

  package var errorDescription: String? {
    switch self {
    case .fixtureFailed(let ruleId):
      return "Rule '\(ruleId)' fixture failed under engine \(EngineVersion.current)."
    case .noSigningKey:
      return "No SSH signing key found."
    }
  }
}
