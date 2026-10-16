import ArgumentParser
import Foundation
import InvariantCore

struct ConfigCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "config",
    abstract: "Modify project analysis inputs in registry.project with impact verification."
  )

  @Option(name: .long, help: "Relative path to Swift index store.")
  var swiftIndex: String?

  @Option(name: .long, parsing: .upToNextOption, help: "Relative path(s) to tsconfig.json.")
  var tsconfig: [String] = []

  @Option(name: .long, help: "Default protected trunk branch name (e.g. main).")
  var defaultBranch: String?

  @Option(name: .long, help: "Custom SSH key path for signing.")
  var key: String?

  func run() async throws {
    let repoRootURL = try CLIHelpers.requireRepoRoot()

    let env = SystemEnvironment.standard
    let registryManager = RegistryManager(environment: env)
    let gitClient = GitClient()
    let manifestValidator = ManifestValidator()
    let discoverer = FixtureDiscoverer()
    let runner = RuleRunner(environment: env)
    let fm = FileManager.default

    var registry = try await registryManager.loadAndVerify(
      repoRoot: repoRootURL,
      installedEngineVersion: CLIHelpers.engineVersion
    )

    if swiftIndex == nil && tsconfig.isEmpty && defaultBranch == nil {
      print("No configuration changes specified. Use --swift-index, --tsconfig, or --default-branch.")
      return
    }

    let oldProject = registry.project ?? ProjectConfig()
    var newProject = oldProject
    if let swiftIndex {
      newProject.swift = SwiftProjectConfig(indexStore: swiftIndex)
    }
    if !tsconfig.isEmpty {
      newProject.ts = TSProjectConfig(tsconfig: tsconfig)
    }
    let oldDefaultBranch = registry.defaultBranch
    if let defaultBranch {
      registry.defaultBranch = defaultBranch
    }

    print("Project Configuration Diff:")
    print("───────────────────────────")
    let oldSwift = oldProject.swift?.indexStore ?? "none"
    let newSwift = newProject.swift?.indexStore ?? "none"
    print("Swift indexStore: \(oldSwift) → \(newSwift)")

    let oldTS = (oldProject.ts?.tsconfig ?? []).joined(separator: ", ")
    let newTS = (newProject.ts?.tsconfig ?? []).joined(separator: ", ")
    print("TS tsconfig:     \(oldTS.isEmpty ? "none" : oldTS) → \(newTS.isEmpty ? "none" : newTS)")
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
      try await gitClient.archiveExtract(
        repoRoot: repoRootURL,
        treeHash: signedTreeHash,
        destinationURL: tempSnapshot
      )

      let manifestData = try Data(contentsOf: tempSnapshot.appendingPathComponent("manifest.json"))
      let manifest = try ManifestParser.parse(data: manifestData, expectedId: ruleId)

      // 1. Fixtures must still pass with newProject
      for target in manifest.targets {
        let cases = try discoverer.discover(ruleDirectory: tempSnapshot, target: target, manifestCodes: manifest.codes)
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
            engineVersion: CLIHelpers.engineVersion
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
        let scopedFiles = manifestValidator.resolveScopedFiles(repoRoot: repoRootURL, scope: targetScope)

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
            engineVersion: CLIHelpers.engineVersion
          )) ?? []

        let violationsNew =
          (try? await runner.execute(
            target: target,
            ruleDirectory: tempSnapshot,
            ruleTreeHash: signedTreeHash,
            request: reqNew,
            engineVersion: CLIHelpers.engineVersion
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

    if CLIHelpers.isInteractive {
      let confirm = CLIHelpers.promptConfirmation(question: "Sign and commit new configuration?", default: true)
      if !confirm {
        print("Aborted.")
        return
      }
    }

    registry.project = newProject
    registry.version += 1

    guard let keyURL = CLIHelpers.promptForSigningKey(customPath: key) else {
      fputs("Error: No SSH signing key found.\n", stderr)
      throw ExitCode(1)
    }

    print("Updating project analysis configuration in registry v\(registry.version)...")
    try await registryManager.saveAndSign(
      registry: registry,
      repoRoot: repoRootURL,
      keyURL: keyURL
    )

    try await gitClient.commit(
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
