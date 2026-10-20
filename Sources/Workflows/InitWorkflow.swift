package import Core
import Foundation
import Terminal

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

    Terminal.info("Initializing invariants in \(repoRootURL.lastPathComponent)...")

    // 1. Resolve signing key first (mandatory prerequisite for init)
    guard let keyURL = SigningKeyWorkflow.resolve(customPath: input.keyPath) else {
      throw InitWorkflowError.noSigningKey
    }

    // 2. Detect language inputs interactively or via flags
    let languagesConfig = try LanguageConfigWorkflow.resolveConfigurations(
      explicitLanguages: input.languages
    )

    guard !languagesConfig.isEmpty else {
      throw InitWorkflowError.noLanguagesConfigured
    }

    // 3. Select default trunk branch
    let defaultBranch: String
    do {
      defaultBranch = try await BranchSelectionWorkflow.selectDefaultBranch(
        explicitBranch: input.branch
      )
    } catch is BranchSelectionError {
      throw InitWorkflowError.noBranchesFound
    }

    // 4. Initialize repository
    let options = InitOptions(
      engineVersion: EngineVersion.current,
      defaultBranch: defaultBranch,
      languages: languagesConfig,
      keyURL: keyURL
    )

    Terminal.info("Signing registry v1 with \(keyURL.lastPathComponent)...")
    try await InitManager.initialize(options: options)

    Terminal.success("Invariants initialized successfully in \(repoRootURL.lastPathComponent) (registry v1).")
    Terminal.hint(
      """
      To enforce invariants automatically on commit or push, add:
         invariants check
      to your pre-commit hook or CI pipeline.
      """
    )
  }
}

package enum InitWorkflowError: LocalizedError, Sendable {
  case noSigningKey
  case noLanguagesConfigured
  case noBranchesFound

  package var errorDescription: String? {
    switch self {
    case .noSigningKey:
      return "No signing key selected. Run 'invariants key generate' or specify --key <path>."
    case .noLanguagesConfigured:
      return
        "Repository initialization failed: at least one supported language must be configured. "
        + "Specify --languages or run interactively in a repository with source files."
    case .noBranchesFound:
      return "Repository initialization failed: no git branches found in this repository."
    }
  }
}
