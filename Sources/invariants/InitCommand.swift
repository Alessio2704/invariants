import ArgumentParser
import Foundation
import InvariantCore

struct InitCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "init",
    abstract: "Initialize invariants in a project and sign registry v1."
  )

  @Option(name: .long, help: "Default branch name (default: auto-detected or main).")
  var branch: String?

  @Option(name: .long, help: "Relative path to Swift index store (e.g. build/Index.noindex/DataStore).")
  var swiftIndex: String?

  @Option(name: .long, parsing: .upToNextOption, help: "Relative path(s) to tsconfig.json.")
  var tsconfig: [String] = []

  @Option(name: .long, help: "Custom SSH key path for signing.")
  var key: String?

  func run() async throws {
    let repoRootURL = try CLIHelpers.requireRepoRoot()

    let env = SystemEnvironment.standard
    let registryManager = RegistryManager(environment: env)
    let gitClient = GitClient()

    print("Initializing invariants in \(repoRootURL.lastPathComponent)...")

    // 1. Detect project inputs interactively or via flags
    let configuredSwiftIndex = selectSwiftIndex(repoRootURL: repoRootURL)
    let configuredTsconfigs = selectTsconfigs(repoRootURL: repoRootURL)

    // 2. Resolve signing key
    guard let keyURL = CLIHelpers.promptForSigningKey(customPath: key) else {
      fputs("Error: No signing key selected. Run 'invariants key generate' or specify --key <path>.\n", stderr)
      throw ExitCode(1)
    }

    // 3. Select default trunk branch
    let defaultBranch = await selectDefaultBranch(repoRootURL: repoRootURL, gitClient: gitClient)

    // 4. Initialize repository
    var projectConfig = ProjectConfig()
    if let configuredSwiftIndex {
      projectConfig.swift = SwiftLanguage.Config(indexStore: configuredSwiftIndex)
    }
    if !configuredTsconfigs.isEmpty {
      projectConfig.ts = TypeScriptLanguage.Config(tsconfig: configuredTsconfigs)
    }

    let initManager = InitManager(registryManager: registryManager, gitClient: gitClient)
    let options = InitOptions(
      engineVersion: CLIHelpers.engineVersion,
      defaultBranch: defaultBranch,
      projectConfig: projectConfig,
      keyURL: keyURL
    )

    print("Signing registry v1 with \(keyURL.lastPathComponent)...")
    try await initManager.initialize(repoRootURL: repoRootURL, options: options)

    print("✓ Invariants initialized successfully in \(repoRootURL.lastPathComponent) (registry v1).")
    print("\n💡 To enforce invariants automatically on commit or push, add:")
    print("   invariants check --stage pre-commit")
    print("to your pre-commit hook or CI pipeline.")
  }

  // MARK: - Helper Methods

  private func selectDefaultBranch(repoRootURL: URL, gitClient: GitClient) async -> String {
    if let branch {
      return branch
    }

    let branches = await gitClient.discoverBranches(repoRoot: repoRootURL)
    let currentBranch = await gitClient.currentBranch(repoRoot: repoRootURL)
    let remoteTrunk = await gitClient.detectRemoteTrunk(repoRoot: repoRootURL)

    guard !branches.isEmpty else { return "main" }

    if CLIHelpers.isInteractive {
      print("\nDiscovered branches in this repository:")
      for (idx, b) in branches.enumerated() {
        var annotation = ""
        if b == remoteTrunk {
          annotation = " (remote trunk)"
        } else if b == "main" && remoteTrunk == nil {
          annotation = " (recommended)"
        }
        if b == currentBranch {
          annotation += " [current]"
        }
        print("  [\(idx + 1)] \(b)\(annotation)")
      }

      let defaultChoice = branches[0]
      let promptText = "Select trunk branch to protect [1-\(branches.count)] (default: [1] \(defaultChoice))"
      let choice = CLIHelpers.prompt(question: promptText)

      if let num = Int(choice), num >= 1, num <= branches.count {
        return branches[num - 1]
      }
      if !choice.isEmpty {
        return choice
      }
      return defaultChoice
    }

    return branches[0]
  }

  private func selectSwiftIndex(repoRootURL: URL) -> String? {
    if let swiftIndex {
      return swiftIndex
    }
    let candidates = InitManager.discoverSwiftIndexCandidates(repoRootURL: repoRootURL)
    guard !candidates.isEmpty else { return nil }

    if CLIHelpers.isInteractive {
      print("\nDiscovered Swift Index candidates:")
      for (idx, cand) in candidates.enumerated() {
        print("  [\(idx + 1)] \(cand)")
      }
      let choice = CLIHelpers.prompt(
        question: "Select candidate [1-\(candidates.count)] or enter path (press Enter to skip)")
      if let num = Int(choice), num >= 1, num <= candidates.count {
        return candidates[num - 1]
      }
      if !choice.isEmpty {
        return choice
      }
      return nil
    }

    return candidates.first
  }

  private func selectTsconfigs(repoRootURL: URL) -> [String] {
    if !tsconfig.isEmpty {
      return tsconfig
    }
    let candidates = InitManager.discoverTsconfigCandidates(repoRootURL: repoRootURL)
    guard !candidates.isEmpty else { return [] }

    if CLIHelpers.isInteractive {
      let joined = candidates.joined(separator: ", ")
      let confirm = CLIHelpers.promptConfirmation(question: "Use discovered tsconfig paths (\(joined))?", default: true)
      if confirm {
        return candidates
      }
      let custom = CLIHelpers.prompt(question: "Enter tsconfig relative path (press Enter to skip)")
      return custom.isEmpty ? [] : [custom]
    }

    return candidates
  }
}
