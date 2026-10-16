import ArgumentParser
import Foundation
import InvariantCore

struct UpgradeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "upgrade",
    abstract: "Re-verify rules and upgrade engine range in registry after an engine version update."
  )

  @Option(name: .long, help: "Custom SSH key path for signing.")
  var key: String?

  @Option(name: .long, help: "Explicit repository root path (used in testing).")
  var repoPath: String?

  func run() async throws {
    let repoRootURL: URL
    if let repoPath {
      repoRootURL = URL(fileURLWithPath: repoPath)
    } else if let found = CLIHelpers.findRepoRoot() {
      repoRootURL = found
    } else {
      fputs("Error: Not inside a git repository.\n", stderr)
      throw ExitCode(1)
    }

    let env = SystemEnvironment.standard
    let registryManager = RegistryManager(environment: env)
    let gitClient = GitClient()
    let manifestValidator = ManifestValidator()
    let discoverer = FixtureDiscoverer()
    let runner = RuleRunner(environment: env)
    let fm = FileManager.default

    var registry = try await registryManager.loadAndVerify(
      repoRoot: repoRootURL,
      installedEngineVersion: CLIHelpers.engineVersion
    )

    let newRange = "^\(CLIHelpers.engineVersion)"
    print("Re-verifying all active rules under engine \(CLIHelpers.engineVersion)...")

    for (ruleId, signedTreeHash) in registry.rules.sorted(by: { $0.key < $1.key }) {
      let tempSnapshot = fm.temporaryDirectory.appendingPathComponent("upgrade_\(ruleId)_\(UUID().uuidString)")
      defer { try? fm.removeItem(at: tempSnapshot) }

      try fm.createDirectory(at: tempSnapshot, withIntermediateDirectories: true)
      try await gitClient.archiveExtract(
        repoRoot: repoRootURL,
        treeHash: signedTreeHash,
        destinationURL: tempSnapshot
      )

      let manifestData = try Data(contentsOf: tempSnapshot.appendingPathComponent("manifest.json"))
      let manifest = try ManifestParser.parse(data: manifestData, expectedId: ruleId)

      // Test fixtures
      for target in manifest.targets {
        let cases = try discoverer.discover(ruleDirectory: tempSnapshot, target: target, manifestCodes: manifest.codes)
        for fixtureCase in cases {
          let req = RuleRequest(
            mode: "fixture",
            repoRoot: fixtureCase.rootURL.path,
            ruleDir: tempSnapshot.path,
            files: fixtureCase.files.map { $0.path },
            project: registry.project
          )
          let violations = try await runner.execute(
            target: target,
            ruleDirectory: tempSnapshot,
            ruleTreeHash: signedTreeHash,
            request: req,
            engineVersion: CLIHelpers.engineVersion
          )
          if fixtureCase.isShouldPass && !violations.isEmpty {
            fputs("Error: Rule '\(ruleId)' fixture failed under engine \(CLIHelpers.engineVersion).\n", stderr)
            throw ExitCode(1)
          }
        }
      }

      // Check repo scope
      for target in manifest.targets {
        guard let scope = manifest.scope[target] else { continue }
        let scopedFiles = manifestValidator.resolveScopedFiles(repoRoot: repoRootURL, scope: scope)
        let req = RuleRequest(
          mode: "repo",
          repoRoot: repoRootURL.path,
          ruleDir: tempSnapshot.path,
          files: scopedFiles.map { $0.path },
          project: registry.project
        )
        _ = try await runner.execute(
          target: target,
          ruleDirectory: tempSnapshot,
          ruleTreeHash: signedTreeHash,
          request: req,
          engineVersion: CLIHelpers.engineVersion
        )
      }
    }

    print("✓ All active rule fixtures and repo checks passed under \(CLIHelpers.engineVersion).")

    if CLIHelpers.isInteractive {
      let confirm = CLIHelpers.promptConfirmation(
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

    guard let keyURL = CLIHelpers.promptForSigningKey(customPath: key) else {
      fputs("Error: No SSH signing key found.\n", stderr)
      throw ExitCode(1)
    }

    try await registryManager.saveAndSign(
      registry: registry,
      repoRoot: repoRootURL,
      keyURL: keyURL
    )

    try await gitClient.commit(
      repoRoot: repoRootURL,
      paths: [
        "invariants/registry.lock",
        "invariants/registry.lock.sig",
      ],
      message: "Upgrade invariants engine range to \(newRange) (registry v\(registry.version))"
    )

    print("✓ Upgraded engine range to \(newRange) in registry v\(registry.version).")
  }
}
