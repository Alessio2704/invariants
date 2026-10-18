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
    name: [.short, .customLong("languages"), .customLong("lang")],
    parsing: .upToNextOption,
    help: ArgumentHelp(
      "Target languages to configure (\(SupportedLanguage.allCases.map(\.rawValue).joined(separator: ", ")))."
    )
  )
  var languages: [SupportedLanguage] = []

  @Option(name: .long, help: "Custom SSH key path for signing.")
  var key: String?

  func run() async throws {
    let repoRootURL = try RepoLocator.requireRepoRoot()

    print("Initializing invariants in \(repoRootURL.lastPathComponent)...")

    // 1. Resolve signing key first (mandatory prerequisite for init)
    guard let keyURL = await SigningKeyResolver.promptForSigningKey(customPath: key) else {
      fputs("Error: No signing key selected. Run 'invariants key generate' or specify --key <path>.\n", stderr)
      throw ExitCode(1)
    }

    let prompter: (any InteractivePrompter)? = CLIUtil.isInteractive ? TerminalPrompter.shared : nil

    // 2. Detect project inputs interactively or via flags
    var projectConfig = ProjectConfig()
    resolveLanguageConfigurations(repoRootURL: repoRootURL, prompter: prompter, into: &projectConfig)

    // 3. Select default trunk branch
    let defaultBranch = await selectDefaultBranch(repoRootURL: repoRootURL, prompter: prompter)

    // 4. Initialize repository
    let options = InitOptions(
      engineVersion: EngineVersion.current,
      defaultBranch: defaultBranch,
      projectConfig: projectConfig,
      keyURL: keyURL
    )

    print("Signing registry v1 with \(keyURL.lastPathComponent)...")
    try await InitManager.initialize(repoRootURL: repoRootURL, options: options)

    print("✓ Invariants initialized successfully in \(repoRootURL.lastPathComponent) (registry v1).")
    print("\n💡 To enforce invariants automatically on commit or push, add:")
    print("   invariants check --stage pre-commit")
    print("to your pre-commit hook or CI pipeline.")
  }

  // MARK: - Helper Methods

  private func resolveLanguageConfigurations(
    repoRootURL: URL,
    prompter: (any InteractivePrompter)?,
    into projectConfig: inout ProjectConfig
  ) {
    let targetLanguages: [SupportedLanguage]

    if !languages.isEmpty {
      targetLanguages = languages
    } else {
      let detected = SupportedLanguage.allCases.filter { $0.spec.hasSources(in: repoRootURL) }
      if !detected.isEmpty {
        if let prompter {
          prompter.printLine("\nDiscovered languages in this repository:")
          for lang in detected {
            let exts = lang.spec.sourceExtensions.map { ".\($0)" }.joined(separator: ", ")
            prompter.printLine("  • \(lang.spec.displayName) (\(exts))")
          }
          let confirmed = prompter.promptConfirmation(
            question: "Configure invariants for discovered languages?",
            default: true
          )
          if confirmed {
            targetLanguages = detected
          } else {
            targetLanguages = promptForLanguages(prompter: prompter)
          }
        } else {
          targetLanguages = detected
        }
      } else {
        if let prompter {
          prompter.printLine("\nNo known source files detected in repository.")
          targetLanguages = promptForLanguages(prompter: prompter)
        } else {
          targetLanguages = []
        }
      }
    }

    for lang in targetLanguages {
      lang.spec.configureInteractively(repoRootURL: repoRootURL, prompter: prompter, into: &projectConfig)
    }
  }

  private func promptForLanguages(prompter: any InteractivePrompter) -> [SupportedLanguage] {
    let options = SupportedLanguage.allCases.map { lang in
      let exts = lang.spec.sourceExtensions.map { ".\($0)" }.joined(separator: ", ")
      return PromptOption(value: lang, label: lang.spec.displayName, annotation: "extensions: \(exts)")
    }
    return prompter.promptMultiSelection(title: "Available languages:", options: options)
  }

  private func selectDefaultBranch(repoRootURL: URL, prompter: (any InteractivePrompter)?) async -> String {
    if let branch {
      return branch
    }

    let branches = await GitClient.discoverBranches(repoRoot: repoRootURL)
    let currentBranch = await GitClient.currentBranch(repoRoot: repoRootURL)
    let remoteTrunk = await GitClient.detectRemoteTrunk(repoRoot: repoRootURL)

    guard !branches.isEmpty else { return "main" }
    guard let prompter else { return branches[0] }

    let options = branches.map { b in
      var annotations: [String] = []
      if b == remoteTrunk {
        annotations.append("remote trunk")
      } else if b == "main" && remoteTrunk == nil {
        annotations.append("recommended")
      }
      if b == currentBranch {
        annotations.append("current")
      }
      let ann = annotations.isEmpty ? nil : annotations.joined(separator: ", ")
      return PromptOption(value: b, label: b, annotation: ann)
    }

    return prompter.promptSelection(
      title: "Discovered branches in this repository:",
      options: options,
      default: 0,
      customHandler: { $0 }
    ) ?? branches[0]
  }
}
