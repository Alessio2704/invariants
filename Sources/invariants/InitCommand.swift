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
      "Target languages to configure (\(SupportedLanguage.allCases.map(\.rawValue).joined(separator: ", ")))."
    )
  )
  var languages: [SupportedLanguage] = []

  @Option(name: .long, help: "Custom SSH key path for signing.")
  var key: String?

  func run() async throws {
    let repoRootURL = try CLIHelpers.requireRepoRoot()

    print("Initializing invariants in \(repoRootURL.lastPathComponent)...")

    // 1. Resolve signing key first (mandatory prerequisite for init)
    guard let keyURL = await CLIHelpers.promptForSigningKey(customPath: key) else {
      fputs("Error: No signing key selected. Run 'invariants key generate' or specify --key <path>.\n", stderr)
      throw ExitCode(1)
    }

    // 2. Detect project inputs interactively or via flags
    var projectConfig = ProjectConfig()
    resolveLanguageConfigurations(repoRootURL: repoRootURL, into: &projectConfig)

    // 3. Select default trunk branch
    let defaultBranch = await selectDefaultBranch(repoRootURL: repoRootURL)

    // 4. Initialize repository
    let options = InitOptions(
      engineVersion: CLIHelpers.engineVersion,
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

  private func resolveLanguageConfigurations(repoRootURL: URL, into projectConfig: inout ProjectConfig) {
    let prompter: (any InteractivePrompter)? = CLIHelpers.isInteractive ? CLIInteractivePrompter() : nil
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
    prompter.printLine("\nAvailable languages:")
    for (idx, lang) in SupportedLanguage.allCases.enumerated() {
      let exts = lang.spec.sourceExtensions.map { ".\($0)" }.joined(separator: ", ")
      prompter.printLine("  [\(idx + 1)] \(lang.spec.displayName) (extensions: \(exts))")
    }
    let choice = prompter.prompt(
      question: "Select languages to configure (comma-separated numbers, e.g. 1, 2 or press Enter to skip)"
    )
    guard !choice.isEmpty else { return [] }
    let numbers = choice.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    return numbers.compactMap { num in
      guard num >= 1 && num <= SupportedLanguage.allCases.count else { return nil }
      return SupportedLanguage.allCases[num - 1]
    }
  }

  private func selectDefaultBranch(repoRootURL: URL) async -> String {
    if let branch {
      return branch
    }

    let branches = await GitClient.discoverBranches(repoRoot: repoRootURL)
    let currentBranch = await GitClient.currentBranch(repoRoot: repoRootURL)
    let remoteTrunk = await GitClient.detectRemoteTrunk(repoRoot: repoRootURL)

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
}
