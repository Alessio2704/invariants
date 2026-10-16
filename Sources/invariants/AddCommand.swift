import ArgumentParser
import Foundation
import InvariantCore

struct AddCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "add",
    abstract: "Lock and activate a draft rule into the signed registry."
  )

  @Argument(help: "The rule ID to add.")
  var id: String

  @Option(name: .long, help: "Custom SSH key path for signing.")
  var key: String?

  func run() async throws {
    let repoRootURL = try CLIHelpers.requireRepoRoot()

    let env = SystemEnvironment.standard
    let registryManager = RegistryManager(environment: env)
    let fingerprintEngine = FingerprintEngine()
    let manifestValidator = ManifestValidator()
    let discoverer = FixtureDiscoverer()
    let runner = RuleRunner(environment: env)
    let gitClient = GitClient()

    // 1. Load registry
    var registry = try await registryManager.loadAndVerify(
      repoRoot: repoRootURL,
      installedEngineVersion: CLIHelpers.engineVersion
    )

    guard registry.rules[id] == nil else {
      fputs("Error: Rule '\(id)' is already active in registry. Use 'invariants update \(id)' instead.\n", stderr)
      throw ExitCode(1)
    }

    let ruleDir = repoRootURL.appendingPathComponent("invariants/rules/\(id)")
    let fm = FileManager.default
    guard fm.fileExists(atPath: ruleDir.path) else {
      fputs("Error: Rule folder not found at \(ruleDir.path)\n", stderr)
      throw ExitCode(1)
    }

    // 2. Validate manifest and structure
    let manifest = try ManifestParser.load(from: ruleDir.appendingPathComponent("manifest.json"), expectedId: id)
    try manifestValidator.validateStructure(
      ruleDirectory: ruleDir,
      manifest: manifest,
      repoRoot: repoRootURL,
      registry: registry,
      isFixtureMode: false
    )

    // 3. Self-test fixtures
    print("Running fixture self-test for '\(id)'...")
    for target in manifest.targets {
      let cases = try discoverer.discover(
        ruleDirectory: ruleDir,
        target: target,
        manifestCodes: manifest.codes
      )
      for fixtureCase in cases {
        let req = RuleRequest(
          mode: "fixture",
          repoRoot: fixtureCase.rootURL.path,
          ruleDir: ruleDir.path,
          files: fixtureCase.files.map { $0.path }
        )
        let violations = try await runner.execute(
          target: target,
          ruleDirectory: ruleDir,
          ruleTreeHash: "add_preview",
          request: req,
          engineVersion: CLIHelpers.engineVersion
        )

        let expected = Set(fixtureCase.expectedViolations)
        let reported = Set(
          violations.map {
            ExpectedViolation(
              relativePath: URL(fileURLWithPath: $0.file).lastPathComponent,
              line: $0.line,
              code: $0.code
            )
          })

        if fixtureCase.isShouldPass && !violations.isEmpty {
          fputs("Error: Fixture '\(fixtureCase.id)' failed: expected 0 violations, got \(violations.count)\n", stderr)
          throw ExitCode(1)
        } else if !fixtureCase.isShouldPass && expected != reported {
          fputs("Error: Fixture '\(fixtureCase.id)' expectation mismatch\n", stderr)
          throw ExitCode(1)
        }
      }
    }
    print("✓ All fixtures passed.")

    // 4. Repo impact preview
    var repoViolationsCount = 0
    for target in manifest.targets {
      guard let targetScope = manifest.scope[target] else { continue }
      let files = manifestValidator.resolveScopedFiles(repoRoot: repoRootURL, scope: targetScope)
      let req = RuleRequest(
        mode: "repo",
        repoRoot: repoRootURL.path,
        ruleDir: ruleDir.path,
        files: files.map { $0.path },
        project: registry.project
      )
      let violations = try await runner.execute(
        target: target,
        ruleDirectory: ruleDir,
        ruleTreeHash: "add_preview",
        request: req,
        engineVersion: CLIHelpers.engineVersion
      )
      repoViolationsCount += violations.count
    }
    print("Repo impact preview: \(repoViolationsCount) violations on current codebase.")

    if CLIHelpers.isInteractive {
      let confirm = CLIHelpers.promptConfirmation(
        question: "Add and lock invariant '\(id)' into registry v\(registry.version + 1)?",
        default: true
      )
      if !confirm {
        print("Aborted.")
        return
      }
    }

    // 5. Compute tree hash
    let treeHash = try await fingerprintEngine.computeFingerprint(repoRoot: repoRootURL, ruleId: id)
    print("Fingerprint: \(treeHash)")

    // 6. Resolve signing key
    guard let keyURL = CLIHelpers.promptForSigningKey(customPath: key) else {
      fputs("Error: No signing key found. Run 'invariants key generate' or specify --key <path>.\n", stderr)
      throw ExitCode(1)
    }

    // 7. Update registry
    registry.version += 1
    registry.rules[id] = treeHash

    print("Signing registry v\(registry.version) with key \(keyURL.lastPathComponent)...")
    try await registryManager.saveAndSign(
      registry: registry,
      repoRoot: repoRootURL,
      keyURL: keyURL
    )

    // 8. Commit
    try await gitClient.commit(
      repoRoot: repoRootURL,
      paths: [
        "invariants/registry.lock",
        "invariants/registry.lock.sig",
        "invariants/rules/\(id)",
      ],
      message: "Add invariant '\(id)' (registry v\(registry.version))"
    )

    print("✓ Rule '\(id)' activated and locked in registry v\(registry.version).")
  }
}
