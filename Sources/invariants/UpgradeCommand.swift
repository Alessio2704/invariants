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

    var registry = try await registryManager.loadAndVerify(
      repoRoot: repoRootURL,
      installedEngineVersion: CLIHelpers.engineVersion
    )

    let newRange = "^\(CLIHelpers.engineVersion)"
    print("Upgrading registry engine range: '\(registry.engine)' → '\(newRange)'...")

    registry.engine = newRange
    registry.version += 1

    guard let keyURL = CLIHelpers.resolveSigningKey(customPath: key) else {
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
