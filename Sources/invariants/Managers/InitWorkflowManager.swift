import ArgumentParser
import Foundation
import InvariantCore

/// CLI-aware orchestrator responsible for executing the project initialization workflow.
enum InitWorkflowManager {
  struct Input {
    var branch: String?
    var languages: [SupportedLanguage]
    var keyPath: String?

    init(branch: String? = nil, languages: [SupportedLanguage] = [], keyPath: String? = nil) {
      self.branch = branch
      self.languages = languages
      self.keyPath = keyPath
    }
  }

  static func execute(input: Input) async throws {
    let repoRootURL = try RepoLocator.requireRepoRoot()
    print("Initializing invariants in \(repoRootURL.lastPathComponent)...")

    // 1. Harvest signing key
    guard let keyURL = await SigningKeyManager.resolveOrPrompt(customPath: input.keyPath) else {
      fputs("Error: No signing key selected. Run 'invariants key generate' or specify --key <path>.\n", stderr)
      throw ExitCode(1)
    }

    // 2. Harvest language configs
    var projectConfig = ProjectConfig()
    LanguageConfigManager.resolveConfigurations(
      explicitLanguages: input.languages,
      repoRootURL: repoRootURL,
      into: &projectConfig
    )

    // 3. Harvest default branch
    let defaultBranch = await BranchSelectionManager.selectDefaultBranch(
      explicitBranch: input.branch,
      repoRootURL: repoRootURL
    )

    // 4. Execute Core initialization
    let options = InitOptions(
      engineVersion: EngineVersion.current,
      defaultBranch: defaultBranch,
      projectConfig: projectConfig,
      keyURL: keyURL
    )

    print("Signing registry v1 with \(keyURL.lastPathComponent)...")
    try await InitManager.initialize(repoRootURL: repoRootURL, options: options)

    // 5. Output guidance
    print("✓ Invariants initialized successfully in \(repoRootURL.lastPathComponent) (registry v1).")
    print("\n💡 To enforce invariants automatically on commit or push, add:")
    print("   invariants check --stage pre-commit")
    print("to your pre-commit hook or CI pipeline.")
  }
}
