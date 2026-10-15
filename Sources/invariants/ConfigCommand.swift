import ArgumentParser
import Foundation
import InvariantCore

struct ConfigCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "config",
    abstract: "Modify project analysis inputs in registry.project with impact verification."
  )

  @Option(name: .long, help: "Relative path to Swift index store.")
  var swiftIndex: String?

  @Option(name: .long, parsing: .upToNextOption, help: "Relative path(s) to tsconfig.json.")
  var tsconfig: [String] = []

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

    var newProject = registry.project ?? ProjectConfig()
    if let swiftIndex {
      newProject.swift = SwiftProjectConfig(indexStore: swiftIndex)
    }
    if !tsconfig.isEmpty {
      newProject.ts = TSProjectConfig(tsconfig: tsconfig)
    }

    registry.project = newProject
    registry.version += 1

    guard let keyURL = CLIHelpers.resolveSigningKey(customPath: key) else {
      fputs("Error: No SSH signing key found.\n", stderr)
      throw ExitCode(1)
    }

    print("Updating project analysis configuration in registry v\(registry.version)...")
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
      message: "Update invariants configuration (registry v\(registry.version))"
    )

    print("✓ Configuration updated in registry v\(registry.version).")
  }
}
