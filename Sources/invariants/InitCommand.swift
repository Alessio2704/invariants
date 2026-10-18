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

  @Option(
    name: [.short, .customLong("languages"), .customLong("language"), .customLong("lang")],
    parsing: .upToNextOption,
    help: ArgumentHelp(
      "Language input in <lang>.<field>=<value> format.",
      discussion: LanguageCLIParser.helpDiscussion
    )
  )
  var languages: [String] = []

  @Option(name: .long, help: "Custom SSH key path for signing.")
  var key: String?

  func run() async throws {
    let repoRootURL = try CLIHelpers.requireRepoRoot()

    let env = SystemEnvironment.standard
    let registryManager = RegistryManager(environment: env)
    let gitClient = GitClient()

    print("Initializing invariants in \(repoRootURL.lastPathComponent)...")

    // 1. Resolve signing key first (mandatory prerequisite for init)
    guard let keyURL = await CLIHelpers.promptForSigningKey(customPath: key) else {
      fputs("Error: No signing key selected. Run 'invariants key generate' or specify --key <path>.\n", stderr)
      throw ExitCode(1)
    }

    // 2. Detect project inputs interactively or via flags
    var projectConfig = ProjectConfig()
    if !languages.isEmpty {
      for entry in languages {
        do {
          try LanguageCLIParser.apply(entry: entry, into: &projectConfig)
        } catch {
          throw ValidationError(error.description)
        }
      }
    } else {
      selectLanguageConfigurations(repoRootURL: repoRootURL, into: &projectConfig)
    }

    // 3. Select default trunk branch
    let defaultBranch = await selectDefaultBranch(repoRootURL: repoRootURL, gitClient: gitClient)

    // 4. Initialize repository
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

  private func selectLanguageConfigurations(repoRootURL: URL, into projectConfig: inout ProjectConfig) {
    let prompter: (any InteractivePrompter)? = CLIHelpers.isInteractive ? CLIInteractivePrompter() : nil
    for lang in SupportedLanguage.allCases {
      guard lang.spec.hasSources(in: repoRootURL) else { continue }
      lang.spec.configureInteractively(repoRootURL: repoRootURL, prompter: prompter, into: &projectConfig)
    }
  }
}
