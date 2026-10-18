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
    let repoRootURL = try RepoLocator.requireRepoRoot()

    print("Initializing invariants in \(repoRootURL.lastPathComponent)...")

    // 1. Resolve signing key first (mandatory prerequisite for init)
    guard let keyURL = await SigningKeyWorkflow.resolveOrPrompt(customPath: input.keyPath) else {
      fputs("Error: No signing key selected. Run 'invariants key generate' or specify --key <path>.\n", stderr)
      throw InitWorkflowError.noSigningKey
    }

    // 2. Detect project inputs interactively or via flags
    var projectConfig = ProjectConfig()
    LanguageConfigWorkflow.resolveConfigurations(
      explicitLanguages: input.languages,
      repoRootURL: repoRootURL,
      into: &projectConfig
    )

    // 3. Select default trunk branch
    let defaultBranch = await BranchSelectionWorkflow.selectDefaultBranch(
      explicitBranch: input.branch,
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

package enum InitWorkflowError: LocalizedError, Sendable {
  case noSigningKey

  package var errorDescription: String? {
    switch self {
    case .noSigningKey:
      return "No signing key selected."
    }
  }
}
