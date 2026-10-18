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

  func run() async throws {
    let repoRootURL = try CLIHelpers.requireRepoRoot()

    let fm = FileManager.default

    // 1. Load registry
    var registry = try await RegistryManager.loadAndVerify(
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
    guard let keyURL = await CLIHelpers.promptForSigningKey(customPath: key) else {
      fputs("Error: No signing key found. Run 'invariants key generate' or specify --key <path>.\n", stderr)
      throw ExitCode(1)
    }

    print("Signing registry v\(registry.version)...")
    try await RegistryManager.saveAndSign(
      registry: registry,
      repoRoot: repoRootURL,
      keyURL: keyURL
    )

    // 4. Commit
    try await GitClient.commit(
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
