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
    guard let keyURL = await SigningKeyManager.resolveOrPrompt(customPath: key) else {
      fputs("Error: No signing key selected. Run 'invariants key generate' or specify --key <path>.\n", stderr)
      throw ExitCode(1)
    }

    // 2. Detect project inputs interactively or via flags
    var projectConfig = ProjectConfig()
    LanguageConfigManager.resolveConfigurations(
      explicitLanguages: languages,
      repoRootURL: repoRootURL,
      into: &projectConfig
    )

    // 3. Select default trunk branch
    let defaultBranch = await BranchSelectionManager.selectDefaultBranch(
      explicitBranch: branch,
      repoRootURL: repoRootURL
    )

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
}
