package import Core
import Foundation
import Terminal

/// Interactive CLI workflow for modifying language analysis configuration in registry.languages with impact verification.
package enum ConfigWorkflow {
  package static func execute(
    languages: [SupportedLanguage],
    defaultBranch: String?,
    keyPath: String?
  ) async throws {
    let repoRootURL = RepoLocator.current
    let env = SystemEnvironment.standard
    let runner = RuleRunner(environment: env)
    let fm = FileManager.default

    // 1. Authorize signing session upfront (fail-fast)
    let session = try SigningSession.authorize(customPath: keyPath)

    var registry = try await RegistryManager.loadAndVerify(
      installedEngineVersion: EngineVersion.current
    )

    guard
      let targetLanguages = try resolveTargetLanguages(
        explicitLanguages: languages,
        defaultBranch: defaultBranch,
        languages: registry.languages
      )
    else {
      return
    }

    let oldLanguages = registry.languages
    let newLanguages = try LanguageConfigWorkflow.configure(
      languages: targetLanguages,
      baseConfig: oldLanguages
    )

    guard !newLanguages.isEmpty else {
      Terminal.info("Configuration rejected: at least one language must remain configured.")
      return
    }

    guard newLanguages != oldLanguages || defaultBranch != nil else {
      Terminal.info("No configuration changes made.")
      return
    }

    let oldDefaultBranch = registry.defaultBranch
    if let defaultBranch {
      registry.defaultBranch = defaultBranch
    }

    Terminal.header("Language Configuration Diff:")
    for lang in SupportedLanguage.allCases {
      let oldDesc = lang.spec.describeConfig(in: oldLanguages)
      let newDesc = lang.spec.describeConfig(in: newLanguages)
      Terminal.field("\(lang.spec.displayName):", value: "\(oldDesc) → \(newDesc)", width: 17)
    }
    if let defaultBranch {
      Terminal.field("Default branch:", value: "\(oldDefaultBranch) → \(defaultBranch)", width: 17)
    }
    Terminal.line()

    // Verify impact on every active rule
    var hasBlindingIssue = false
    for (ruleId, signedTreeHash) in registry.rules.sorted(by: { $0.key < $1.key }) {
      let tempSnapshot = fm.temporaryDirectory.appendingPathComponent("cfg_check_\(ruleId)_\(UUID().uuidString)")
      defer { try? fm.removeItem(at: tempSnapshot) }

      try fm.createDirectory(at: tempSnapshot, withIntermediateDirectories: true)
      try await GitClient.archiveExtract(
        treeHash: signedTreeHash,
        destinationURL: tempSnapshot
      )

      let manifest = try ManifestParser.load(
        from: tempSnapshot.appendingPathComponent("manifest.json"), expectedId: ruleId)

      // 1. Fixtures must still pass with newLanguages
      for target in manifest.targets {
        let cases = try FixtureDiscoverer.discover(
          ruleDirectory: tempSnapshot, target: target, manifestCodes: manifest.codes)
        for fixtureCase in cases {
          let req = RuleRequest(
            mode: "fixture",
            repoRoot: fixtureCase.rootURL.path,
            ruleDir: tempSnapshot.path,
            files: fixtureCase.files.map { $0.path },
            languages: newLanguages
          )
          let violations = try await runner.execute(
            target: target,
            ruleDirectory: tempSnapshot,
            ruleTreeHash: signedTreeHash,
            request: req,
            engineVersion: EngineVersion.current
          )
          if fixtureCase.isShouldPass && !violations.isEmpty {
            throw ConfigWorkflowError.fixtureFailed(ruleId)
          }
        }
      }

      // 2. Repo check: compare old vs new files and violations
      for target in manifest.targets {
        guard let targetScope = manifest.scope[target] else { continue }
        let scopedFiles = ManifestValidator.resolveScopedFiles(
          scope: targetScope, target: target)

        let reqOld = RuleRequest(
          mode: "repo",
          repoRoot: repoRootURL.path,
          ruleDir: tempSnapshot.path,
          files: scopedFiles.map { $0.path },
          languages: oldLanguages
        )
        let reqNew = RuleRequest(
          mode: "repo",
          repoRoot: repoRootURL.path,
          ruleDir: tempSnapshot.path,
          files: scopedFiles.map { $0.path },
          languages: newLanguages
        )

        let violationsOld =
          (try? await runner.execute(
            target: target,
            ruleDirectory: tempSnapshot,
            ruleTreeHash: signedTreeHash,
            request: reqOld,
            engineVersion: EngineVersion.current
          )) ?? []

        let violationsNew =
          (try? await runner.execute(
            target: target,
            ruleDirectory: tempSnapshot,
            ruleTreeHash: signedTreeHash,
            request: reqNew,
            engineVersion: EngineVersion.current
          )) ?? []

        let dropped = Set(violationsOld).subtracting(Set(violationsNew))
        if !dropped.isEmpty {
          let fileList = dropped.prefix(3).map { "\($0.file):\($0.line)" }.joined(separator: ", ")
          let extra = dropped.count > 3 ? " and \(dropped.count - 3) more" : ""
          let countSummary = "Total: \(violationsOld.count) → \(violationsNew.count)."
          Terminal.error(
            "BLINDED: Rule '\(ruleId)' dropped \(dropped.count) violation(s) (\(fileList)\(extra))! \(countSummary)"
          )
          hasBlindingIssue = true
        }
      }
    }

    if hasBlindingIssue {
      throw ConfigWorkflowError.blindingDetected
    }

    let confirm = try TerminalPrompt.promptConfirmation(
      question: "Sign and commit new configuration?", default: true)
    guard confirm else {
      Terminal.info("Aborted.")
      return
    }

    registry.languages = newLanguages
    registry.version += 1

    Terminal.info("Updating language analysis configuration in registry v\(registry.version)...")
    try await RegistryManager.saveAndSign(
      registry: registry,
      keyURL: session.privateKeyURL
    )

    try await GitClient.commit(
      paths: [
        "invariants/registry.lock",
        "invariants/registry.lock.sig",
      ],
      message: "Update invariants configuration (registry v\(registry.version))"
    )

    Terminal.success("Configuration updated in registry v\(registry.version).")
  }

  private static func resolveTargetLanguages(
    explicitLanguages: [SupportedLanguage],
    defaultBranch: String?,
    languages: LanguagesConfig
  ) throws -> [SupportedLanguage]? {
    guard explicitLanguages.isEmpty else {
      return explicitLanguages
    }

    guard defaultBranch == nil else {
      return []
    }

    let options = SupportedLanguage.allCases.map { lang in
      let currentDesc = lang.spec.describeConfig(in: languages)
      return TerminalPrompt.Option(value: lang, label: lang.spec.displayName, annotation: "current: \(currentDesc)")
    }
    let selected = try TerminalPrompt.promptMultiSelection(
      title: "Select language to reconfigure:", options: options)
    guard !selected.isEmpty else {
      Terminal.info("No configuration changes specified.")
      return nil
    }
    return selected
  }
}

package enum ConfigWorkflowError: LocalizedError, Sendable {
  case fixtureFailed(String)
  case blindingDetected

  package var errorDescription: String? {
    switch self {
    case .fixtureFailed(let ruleId):
      return "Rule '\(ruleId)' fixture failed under new config."
    case .blindingDetected:
      return "Configuration change rejected: new inputs blind active rules."
    }
  }
}
