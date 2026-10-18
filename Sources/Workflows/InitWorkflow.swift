package import Core
import Foundation

/// Interactive CLI workflow responsible for end-to-end repository initialization.
package enum InitWorkflow {
  package struct Input: Sendable {
    package var branch: String?
    package var languages: [SupportedLanguage]
    package var keyPath: String?

    package init(
      branch: String? = nil,
      languages: [SupportedLanguage] = [],
      keyPath: String? = nil
    ) {
      self.branch = branch
      self.languages = languages
      self.keyPath = keyPath
    }
  }

  package static func execute(input: Input) async throws {
    let repoRootURL = RepoLocator.current

    print("Initializing invariants in \(repoRootURL.lastPathComponent)...")

    // 1. Resolve signing key first (mandatory prerequisite for init)
    guard let keyURL = await SigningKeyWorkflow.resolveOrPrompt(customPath: input.keyPath) else {
      fputs("Error: No signing key selected. Run 'invariants key generate' or specify --key <path>.\n", stderr)
      throw InitWorkflowError.noSigningKey
    }

    // 2. Detect language inputs interactively or via flags
    let languagesConfig = LanguageConfigWorkflow.resolveConfigurations(
      explicitLanguages: input.languages
    )

    guard !languagesConfig.isEmpty else {
      let msg =
        "Error: At least one supported language must be configured. "
        + "Specify --languages or run interactively in a repository with source files.\n"
      fputs(msg, stderr)
      throw InitWorkflowError.noLanguagesConfigured
    }

    // 3. Select default trunk branch
    let defaultBranch = await BranchSelectionWorkflow.selectDefaultBranch(
      explicitBranch: input.branch
    )

    // 4. Initialize repository
    let options = InitOptions(
      engineVersion: EngineVersion.current,
      defaultBranch: defaultBranch,
      languages: languagesConfig,
      keyURL: keyURL
    )

    print("Signing registry v1 with \(keyURL.lastPathComponent)...")
    try await InitManager.initialize(options: options)

    print("✓ Invariants initialized successfully in \(repoRootURL.lastPathComponent) (registry v1).")
    print("\n💡 To enforce invariants automatically on commit or push, add:")
    print("   invariants check --stage pre-commit")
    print("to your pre-commit hook or CI pipeline.")
  }
}

package enum InitWorkflowError: LocalizedError, Sendable {
  case noSigningKey
  case noLanguagesConfigured

  package var errorDescription: String? {
    switch self {
    case .noSigningKey:
      return "No signing key selected."
    case .noLanguagesConfigured:
      return "Repository initialization failed: at least one supported language must be configured."
    }
  }
}
