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

  @Option(name: .long, help: "Confirm update by providing the exact rule ID when weakening is detected.")
  var confirmId: String?

  @Flag(name: .long, help: "Confirm update even if red-flag weakening is detected.")
  var confirm: Bool = false

  func run() async throws {
    let repoRootURL = try CLIHelpers.requireRepoRoot()
    let env = SystemEnvironment.standard
    let registryManager = RegistryManager(environment: env)
    let gitClient = GitClient()
    let fm = FileManager.default

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

    let tempOldSnapshot = fm.temporaryDirectory.appendingPathComponent("old_snapshot_\(id)_\(UUID().uuidString)")
    defer { try? fm.removeItem(at: tempOldSnapshot) }

    try fm.createDirectory(at: tempOldSnapshot, withIntermediateDirectories: true)
    try await gitClient.archiveExtract(
      repoRoot: repoRootURL,
      treeHash: oldSignedTreeHash,
      destinationURL: tempOldSnapshot
    )

    let (oldManifest, newManifest) = try parseManifests(
      ruleDir: ruleDir,
      tempOldSnapshot: tempOldSnapshot,
      repoRootURL: repoRootURL,
      registry: registry
    )

    let context = UpdateContext(
      ruleDir: ruleDir,
      tempOldSnapshot: tempOldSnapshot,
      repoRootURL: repoRootURL,
      registry: registry,
      oldSignedTreeHash: oldSignedTreeHash,
      env: env
    )

    try await checkWeakening(
      oldManifest: oldManifest,
      newManifest: newManifest,
      context: context
    )

    try await verifyFixtures(ruleDir: ruleDir, manifest: newManifest, env: env)

    try await saveAndCommitUpdate(
      repoRootURL: repoRootURL,
      oldSignedTreeHash: oldSignedTreeHash,
      registry: &registry,
      registryManager: registryManager,
      gitClient: gitClient
    )
  }
}

// MARK: - Pipeline Steps

private struct UpdateContext {
  let ruleDir: URL
  let tempOldSnapshot: URL
  let repoRootURL: URL
  let registry: Registry
  let oldSignedTreeHash: String
  let env: SystemEnvironment
}

extension UpdateCommand {
  private func parseManifests(
    ruleDir: URL,
    tempOldSnapshot: URL,
    repoRootURL: URL,
    registry: Registry
  ) throws -> (RuleManifest, RuleManifest) {
    let manifestValidator = ManifestValidator()
    let oldManifest = try ManifestParser.load(
      from: tempOldSnapshot.appendingPathComponent("manifest.json"),
      expectedId: id
    )
    let newManifest = try ManifestParser.load(
      from: ruleDir.appendingPathComponent("manifest.json"),
      expectedId: id
    )

    try manifestValidator.validateStructure(
      ruleDirectory: ruleDir,
      manifest: newManifest,
      repoRoot: repoRootURL,
      registry: registry,
      isFixtureMode: false
    )
    return (oldManifest, newManifest)
  }

  private func checkWeakening(
    oldManifest: RuleManifest,
    newManifest: RuleManifest,
    context: UpdateContext
  ) async throws {
    let discoverer = FixtureDiscoverer()
    let weakeningDetector = WeakeningDetector()
    let manifestValidator = ManifestValidator()
    let runner = RuleRunner(environment: context.env)

    var oldCases: [FixtureCase] = []
    for target in oldManifest.targets {
      if let cases = try? discoverer.discover(
        ruleDirectory: context.tempOldSnapshot,
        target: target,
        manifestCodes: oldManifest.codes
      ) {
        oldCases.append(contentsOf: cases)
      }
    }

    var newCases: [FixtureCase] = []
    for target in newManifest.targets {
      let cases = try discoverer.discover(
        ruleDirectory: context.ruleDir,
        target: target,
        manifestCodes: newManifest.codes
      )
      newCases.append(contentsOf: cases)
    }

    var weakening = weakeningDetector.detect(
      ruleId: id,
      oldManifest: oldManifest,
      newManifest: newManifest,
      oldCases: oldCases,
      newCases: newCases
    )

    let (oldV, newV) = await countRepoViolations(
      manifest: newManifest,
      context: context,
      manifestValidator: manifestValidator,
      runner: runner
    )

    if newV < oldV {
      var updated = weakening.items
      updated.append(
        WeakeningItem(
          severity: .red,
          category: "repoViolationsDropped",
          message: "Repo violations dropped from \(oldV) to \(newV) for unchanged product code."
        )
      )
      weakening = WeakeningReport(ruleId: id, items: updated)
    }

    try handleWeakeningReport(weakening)
  }

  private func countRepoViolations(
    manifest: RuleManifest,
    context: UpdateContext,
    manifestValidator: ManifestValidator,
    runner: RuleRunner
  ) async -> (Int, Int) {
    var oldRepoViolationsCount = 0
    var newRepoViolationsCount = 0

    for target in manifest.targets {
      guard let scope = manifest.scope[target] else { continue }
      let scopedFiles = manifestValidator.resolveScopedFiles(repoRoot: context.repoRootURL, scope: scope)

      let oldReq = RuleRequest(
        mode: "repo",
        repoRoot: context.repoRootURL.path,
        ruleDir: context.tempOldSnapshot.path,
        files: scopedFiles.map { $0.path },
        project: context.registry.project
      )
      let newReq = RuleRequest(
        mode: "repo",
        repoRoot: context.repoRootURL.path,
        ruleDir: context.ruleDir.path,
        files: scopedFiles.map { $0.path },
        project: context.registry.project
      )

      let oldRes =
        (try? await runner.execute(
          target: target,
          ruleDirectory: context.tempOldSnapshot,
          ruleTreeHash: context.oldSignedTreeHash,
          request: oldReq,
          engineVersion: CLIHelpers.engineVersion
        )) ?? []

      let newRes =
        (try? await runner.execute(
          target: target,
          ruleDirectory: context.ruleDir,
          ruleTreeHash: "update_preview",
          request: newReq,
          engineVersion: CLIHelpers.engineVersion
        )) ?? []

      oldRepoViolationsCount += oldRes.count
      newRepoViolationsCount += newRes.count
    }
    return (oldRepoViolationsCount, newRepoViolationsCount)
  }

  private func handleWeakeningReport(_ weakening: WeakeningReport) throws {
    if weakening.hasRedFlags {
      print("\n🔴 WEAKENING DETECTED in invariant '\(id)':")
      for item in weakening.items where item.severity == .red {
        print("  ✗ [\(item.category)] \(item.message)")
      }

      var isConfirmed = confirm || (confirmId == id)
      if !isConfirmed && CLIHelpers.isInteractive {
        let typed = CLIHelpers.prompt(question: "\nTo confirm this weakening, please type the rule id '\(id)'")
        if typed == id {
          isConfirmed = true
        }
      }

      if !isConfirmed {
        fputs("\nUpdate blocked by weakening guard. Pass --confirm-id \(id) or type rule id to confirm.\n", stderr)
        throw ExitCode(1)
      }
    }

    if weakening.hasGreenFlags {
      print("\n🟢 Legitimate additions:")
      for item in weakening.items where item.severity == .green {
        print("  ✓ [\(item.category)] \(item.message)")
      }
    }
  }

  private func verifyFixtures(ruleDir: URL, manifest: RuleManifest, env: SystemEnvironment) async throws {
    let discoverer = FixtureDiscoverer()
    let runner = RuleRunner(environment: env)
    print("\nVerifying fixtures for '\(id)'...")

    for target in manifest.targets {
      let cases = try discoverer.discover(ruleDirectory: ruleDir, target: target, manifestCodes: manifest.codes)
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
  }

  private func saveAndCommitUpdate(
    repoRootURL: URL,
    oldSignedTreeHash: String,
    registry: inout Registry,
    registryManager: RegistryManager,
    gitClient: GitClient
  ) async throws {
    let fingerprintEngine = FingerprintEngine()
    let newTreeHash = try await fingerprintEngine.computeFingerprint(repoRoot: repoRootURL, ruleId: id)
    guard newTreeHash != oldSignedTreeHash else {
      print("Notice: No changes detected. Rule '\(id)' is already at tree \(newTreeHash).")
      return
    }

    guard let keyURL = CLIHelpers.promptForSigningKey(customPath: key) else {
      fputs("Error: No signing key found. Run 'invariants key generate' or specify --key <path>.\n", stderr)
      throw ExitCode(1)
    }

    registry.version += 1
    registry.rules[id] = newTreeHash

    print("Signing registry v\(registry.version) with \(keyURL.lastPathComponent)...")
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
        "invariants/rules/\(id)",
      ],
      message: "Update invariant '\(id)' (registry v\(registry.version))"
    )

    print("✓ Rule '\(id)' updated to \(newTreeHash) in registry v\(registry.version).")
  }
}
