import ArgumentParser
import Foundation
import InvariantCore

struct RemoveCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "remove",
    abstract: "Deactivate an invariant rule and remove it from the signed registry."
  )

  @Argument(help: "The rule ID to remove.")
  var id: String

  @Flag(name: .long, help: "Delete the rule directory from disk instead of keeping it as a draft.")
  var delete: Bool = false

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
    let fm = FileManager.default

    // 1. Load registry
    var registry = try await registryManager.loadAndVerify(
      repoRoot: repoRootURL,
      installedEngineVersion: CLIHelpers.engineVersion
    )

    guard registry.rules[id] != nil else {
      fputs("Error: Rule '\(id)' is not in registry.\n", stderr)
      throw ExitCode(1)
    }

    let ruleDir = repoRootURL.appendingPathComponent("invariants/rules/\(id)")

    // 2. Remove rule
    registry.rules.removeValue(forKey: id)
    registry.version += 1

    var pathsToCommit = [
      "invariants/registry.lock",
      "invariants/registry.lock.sig",
    ]

    if delete {
      if fm.fileExists(atPath: ruleDir.path) {
        try fm.removeItem(at: ruleDir)
        pathsToCommit.append("invariants/rules/\(id)")
      }
    }

    if CLIHelpers.isInteractive {
      let confirm = CLIHelpers.promptConfirmation(
        question: "Deactivate and remove invariant '\(id)' from registry v\(registry.version + 1)?",
        default: true
      )
      if !confirm {
        print("Aborted.")
        return
      }
    }

    // 3. Resolve key and sign
    guard let keyURL = CLIHelpers.promptForSigningKey(customPath: key, repoRoot: repoRootURL) else {
      fputs("Error: No SSH signing key found. Specify --key <path>\n", stderr)
      throw ExitCode(1)
    }

    print("Signing registry v\(registry.version)...")
    try await registryManager.saveAndSign(
      registry: registry,
      repoRoot: repoRootURL,
      keyURL: keyURL
    )

    // 4. Commit
    try await gitClient.commit(
      repoRoot: repoRootURL,
      paths: pathsToCommit,
      message: "Remove invariant '\(id)' (registry v\(registry.version))"
    )

    print("✓ Rule '\(id)' removed from registry v\(registry.version).")
    if !delete {
      print("Notice: Directory kept as draft at invariants/rules/\(id)/.")
    }
  }
}
