import ArgumentParser
import Foundation
import InvariantCore

struct ConfigCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "config",
    abstract: "Modify project analysis inputs in registry.project with impact verification."
  )

  @Option(
    name: [.short, .customLong("languages"), .customLong("language"), .customLong("lang")],
    parsing: .upToNextOption,
    help: ArgumentHelp(
      "Target languages to reconfigure (\(SupportedLanguage.allCases.map(\.rawValue).joined(separator: ", ")))."
    )
  )
  var languages: [SupportedLanguage] = []

  @Option(name: .long, help: "Default protected trunk branch name (e.g. main).")
  var defaultBranch: String?

  @Option(name: .long, help: "Custom SSH key path for signing.")
  var key: String?

  func run() async throws {
    let repoRootURL = try RepoLocator.requireRepoRoot()

    let env = SystemEnvironment.standard
    let runner = RuleRunner(environment: env)
    let fm = FileManager.default

    var registry = try await RegistryManager.loadAndVerify(
      repoRoot: repoRootURL,
      installedEngineVersion: EngineVersion.current
    )

    let targetLanguages: [SupportedLanguage]
    if !languages.isEmpty {
      targetLanguages = languages
    } else if defaultBranch == nil && CLIUtil.isInteractive {
      let prompter = TerminalPrompter.shared
      let options = SupportedLanguage.allCases.map { lang in
        let currentDesc = lang.spec.describeConfig(in: registry.project ?? ProjectConfig())
        return PromptOption(value: lang, label: lang.spec.displayName, annotation: "current: \(currentDesc)")
      }
      targetLanguages = prompter.promptMultiSelection(title: "Select language to reconfigure:", options: options)
      guard !targetLanguages.isEmpty else {
        print("No configuration changes specified.")
        return
      }
    } else if defaultBranch == nil {
      print("No configuration changes specified. Use --languages or --default-branch.")
      return
    } else {
      targetLanguages = []
    }

    let prompter: (any InteractivePrompter)? = CLIUtil.isInteractive ? TerminalPrompter.shared : nil
    let oldProject = registry.project ?? ProjectConfig()
    var newProject = oldProject
    for lang in targetLanguages {
      lang.spec.configureInteractively(repoRootURL: repoRootURL, prompter: prompter, into: &newProject)
    }

    if newProject == oldProject && defaultBranch == nil {
      print("No configuration changes made.")
      return
    }

    let oldDefaultBranch = registry.defaultBranch
    if let defaultBranch {
      registry.defaultBranch = defaultBranch
    }

    print("Project Configuration Diff:")
    print("───────────────────────────")
    for lang in SupportedLanguage.allCases {
      let oldDesc = lang.spec.describeConfig(in: oldProject)
      let newDesc = lang.spec.describeConfig(in: newProject)
      let label = "\(lang.spec.displayName):".padding(toLength: 17, withPad: " ", startingAt: 0)
      print("\(label)\(oldDesc) → \(newDesc)")
    }
    if let defaultBranch {
      print("Default branch:   \(oldDefaultBranch) → \(defaultBranch)")
    }
    print("")

    // Verify impact on every active rule
    var hasBlindingIssue = false
    for (ruleId, signedTreeHash) in registry.rules.sorted(by: { $0.key < $1.key }) {
      let tempSnapshot = fm.temporaryDirectory.appendingPathComponent("cfg_check_\(ruleId)_\(UUID().uuidString)")
      defer { try? fm.removeItem(at: tempSnapshot) }

      try fm.createDirectory(at: tempSnapshot, withIntermediateDirectories: true)
      try await GitClient.archiveExtract(
        repoRoot: repoRootURL,
        treeHash: signedTreeHash,
        destinationURL: tempSnapshot
      )

      let manifest = try ManifestParser.load(
        from: tempSnapshot.appendingPathComponent("manifest.json"), expectedId: ruleId)

      // 1. Fixtures must still pass with newProject
      for target in manifest.targets {
        let cases = try FixtureDiscoverer.discover(
          ruleDirectory: tempSnapshot, target: target, manifestCodes: manifest.codes)
        for fixtureCase in cases {
          let req = RuleRequest(
            mode: "fixture",
            repoRoot: fixtureCase.rootURL.path,
            ruleDir: tempSnapshot.path,
            files: fixtureCase.files.map { $0.path },
            project: newProject
          )
          let violations = try await runner.execute(
            target: target,
            ruleDirectory: tempSnapshot,
            ruleTreeHash: signedTreeHash,
            request: req,
            engineVersion: EngineVersion.current
          )
          if fixtureCase.isShouldPass && !violations.isEmpty {
            fputs("Error: Rule '\(ruleId)' fixture failed under new config.\n", stderr)
            throw ExitCode(1)
          }
        }
      }

      // 2. Repo check: compare old vs new files and violations
      for target in manifest.targets {
        guard let targetScope = manifest.scope[target] else { continue }
        let scopedFiles = ManifestValidator.resolveScopedFiles(repoRoot: repoRootURL, scope: targetScope)

        let reqOld = RuleRequest(
          mode: "repo",
          repoRoot: repoRootURL.path,
          ruleDir: tempSnapshot.path,
          files: scopedFiles.map { $0.path },
          project: oldProject
        )
        let reqNew = RuleRequest(
          mode: "repo",
          repoRoot: repoRootURL.path,
          ruleDir: tempSnapshot.path,
          files: scopedFiles.map { $0.path },
          project: newProject
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

        if violationsNew.count < violationsOld.count {
          print(
            "🔴 BLINDED: Rule '\(ruleId)' reports fewer violations (\(violationsOld.count) → \(violationsNew.count))!"
          )
          hasBlindingIssue = true
        }
      }
    }

    if hasBlindingIssue {
      fputs("\nConfiguration change rejected: new inputs blind active rules.\n", stderr)
      throw ExitCode(1)
    }

    if CLIUtil.isInteractive {
      let confirm = TerminalPrompter.shared.promptConfirmation(
        question: "Sign and commit new configuration?", default: true)
      if !confirm {
        print("Aborted.")
        return
      }
    }

    registry.project = newProject
    registry.version += 1

    guard let keyURL = await SigningKeyResolver.promptForSigningKey(customPath: key) else {
      fputs("Error: No SSH signing key found.\n", stderr)
      throw ExitCode(1)
    }

    print("Updating project analysis configuration in registry v\(registry.version)...")
    try await RegistryManager.saveAndSign(
      registry: registry,
      repoRoot: repoRootURL,
      keyURL: keyURL
    )

    try await GitClient.commit(
      repoRoot: repoRootURL,
      paths: [
        "invariants/registry.lock",
        "invariants/registry.lock.sig",
      ],
      message: "Update invariants configuration (registry v\(registry.version))"
    )

    print("✓ Configuration updated in registry v\(registry.version).")
  }
}
