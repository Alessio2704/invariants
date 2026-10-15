import ArgumentParser
import Foundation
import InvariantCore

struct UpdateCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "update",
    abstract: "Update an active invariant rule with weakening detection and signature locking."
  )

  @Argument(help: "The rule ID to update.")
  var id: String

  @Option(name: .long, help: "Custom SSH key path for signing.")
  var key: String?

  @Flag(name: .long, help: "Confirm update even if red-flag weakening is detected.")
  var confirm: Bool = false

  @Option(name: .long, help: "Explicit repository root path (used in testing).")
  var repoPath: String?

  func run() async throws {
    let repoRootURL: URL
    if let repoPath {
      repoRootURL = URL(fileURLWithPath: repoPath)
    } else if let found = CLIHelpers.findRepoRoot() {
      repoRootURL = found
    } else {
      fputs("Error: Not inside a git repository.\n", stderr)
      throw ExitCode(1)
    }

    let env = SystemEnvironment.standard
    let registryManager = RegistryManager(environment: env)
    let fingerprintEngine = FingerprintEngine()
    let manifestValidator = ManifestValidator()
    let weakeningDetector = WeakeningDetector()
    let discoverer = FixtureDiscoverer()
    let runner = RuleRunner(environment: env)
    let gitClient = GitClient()
    let fm = FileManager.default

    // 1. Load registry
    var registry = try await registryManager.loadAndVerify(
      repoRoot: repoRootURL,
      installedEngineVersion: CLIHelpers.engineVersion
    )

    guard let oldSignedTreeHash = registry.rules[id] else {
      fputs("Error: Rule '\(id)' is not currently active. Use 'invariants add \(id)' to activate it.\n", stderr)
      throw ExitCode(1)
    }

    let ruleDir = repoRootURL.appendingPathComponent("invariants/rules/\(id)")
    guard fm.fileExists(atPath: ruleDir.path) else {
      fputs("Error: Working tree directory missing at \(ruleDir.path)\n", stderr)
      throw ExitCode(1)
    }

    // 2. Extract old signed snapshot
    let tempOldSnapshot = fm.temporaryDirectory.appendingPathComponent("old_snapshot_\(id)_\(UUID().uuidString)")
    defer {
      try? fm.removeItem(at: tempOldSnapshot)
    }

    try fm.createDirectory(at: tempOldSnapshot, withIntermediateDirectories: true)
    try await gitClient.archiveExtract(
      repoRoot: repoRootURL,
      treeHash: oldSignedTreeHash,
      destinationURL: tempOldSnapshot
    )

    // 3. Parse old and new manifests
    let oldManifestData = try Data(contentsOf: tempOldSnapshot.appendingPathComponent("manifest.json"))
    let oldManifest = try ManifestParser.parse(data: oldManifestData, expectedId: id)

    let newManifestData = try Data(contentsOf: ruleDir.appendingPathComponent("manifest.json"))
    let newManifest = try ManifestParser.parse(data: newManifestData, expectedId: id)

    try manifestValidator.validateStructure(
      ruleDirectory: ruleDir,
      manifest: newManifest,
      repoRoot: repoRootURL,
      registry: registry,
      isFixtureMode: false
    )

    // 4. Discover old and new fixtures
    var oldCases: [FixtureCase] = []
    for target in oldManifest.targets {
      let discovered = try? discoverer.discover(
        ruleDirectory: tempOldSnapshot,
        target: target,
        manifestCodes: oldManifest.codes
      )
      if let cases = discovered {
        oldCases.append(contentsOf: cases)
      }
    }

    var newCases: [FixtureCase] = []
    for target in newManifest.targets {
      let cases = try discoverer.discover(ruleDirectory: ruleDir, target: target, manifestCodes: newManifest.codes)
      newCases.append(contentsOf: cases)
    }

    // 5. Weakening Analysis
    let weakening = weakeningDetector.detect(
      ruleId: id,
      oldManifest: oldManifest,
      newManifest: newManifest,
      oldCases: oldCases,
      newCases: newCases
    )

    if weakening.hasRedFlags {
      print("\n🔴 WEAKENING DETECTED in invariant '\(id)':")
      for item in weakening.items where item.severity == .red {
        print("  ✗ [\(item.category)] \(item.message)")
      }
      if !confirm {
        fputs("\nUpdate blocked by weakening guard. Pass --confirm or resolve the weakening items.\n", stderr)
        throw ExitCode(1)
      }
    }

    if weakening.hasGreenFlags {
      print("\n🟢 Legitimate additions:")
      for item in weakening.items where item.severity == .green {
        print("  ✓ [\(item.category)] \(item.message)")
      }
    }

    // 6. Test all new fixtures
    print("\nVerifying fixtures for '\(id)'...")
    for target in newManifest.targets {
      let cases = try discoverer.discover(ruleDirectory: ruleDir, target: target, manifestCodes: newManifest.codes)
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
          ruleTreeHash: "update_preview",
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
          fputs("Error: Fixture '\(fixtureCase.id)' failed: expected 0, got \(violations.count)\n", stderr)
          throw ExitCode(1)
        } else if !fixtureCase.isShouldPass && expected != reported {
          fputs("Error: Fixture '\(fixtureCase.id)' mismatch\n", stderr)
          throw ExitCode(1)
        }
      }
    }
    print("✓ All fixtures green.")

    // 7. Compute new tree hash
    let newTreeHash = try await fingerprintEngine.computeFingerprint(repoRoot: repoRootURL, ruleId: id)
    guard newTreeHash != oldSignedTreeHash else {
      print("Notice: No changes detected. Rule '\(id)' is already at tree \(newTreeHash).")
      return
    }

    // 8. Resolve signing key
    guard let keyURL = CLIHelpers.resolveSigningKey(customPath: key) else {
      fputs("Error: No SSH signing key found. Specify --key <path>\n", stderr)
      throw ExitCode(1)
    }

    // 9. Update registry & sign
    registry.version += 1
    registry.rules[id] = newTreeHash

    print("Signing registry v\(registry.version) with \(keyURL.lastPathComponent)...")
    try await registryManager.saveAndSign(
      registry: registry,
      repoRoot: repoRootURL,
      keyURL: keyURL
    )

    // 10. Commit
    try await gitClient.commit(
      repoRoot: repoRootURL,
      paths: [
        "invariants/registry.lock",
        "invariants/registry.lock.sig",
        "invariants/rules/\(id)",
      ],
      message: "Update invariant '\(id)' (registry v\(registry.version))"
    )

    print("✓ Rule '\(id)' updated to \(newTreeHash) in registry v\(registry.version).")
  }
}
