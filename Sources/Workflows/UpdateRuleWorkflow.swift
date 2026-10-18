import Core
import Foundation
import Terminal

/// Interactive CLI workflow to update an active invariant rule with weakening detection and signature locking.
package enum UpdateRuleWorkflow {
  package struct Input: Sendable {
    package let id: String
    package let keyPath: String?
    package let confirmId: String?
    package let confirm: Bool

    package init(id: String, keyPath: String? = nil, confirmId: String? = nil, confirm: Bool = false) {
      self.id = id
      self.keyPath = keyPath
      self.confirmId = confirmId
      self.confirm = confirm
    }
  }

  package static func execute(input: Input) async throws {
    let repoRootURL = try RepoLocator.requireRepoRoot()
    let env = SystemEnvironment.standard
    let fm = FileManager.default

    var registry = try await RegistryManager.loadAndVerify(
      repoRoot: repoRootURL,
      installedEngineVersion: EngineVersion.current
    )

    guard let oldSignedTreeHash = registry.rules[input.id] else {
      throw UpdateRuleWorkflowError.notActive(input.id)
    }

    let ruleDir = repoRootURL.appendingPathComponent("invariants/rules/\(input.id)")
    guard fm.fileExists(atPath: ruleDir.path) else {
      throw UpdateRuleWorkflowError.directoryMissing(ruleDir.path)
    }

    let tempOldSnapshot = fm.temporaryDirectory.appendingPathComponent("old_snapshot_\(input.id)_\(UUID().uuidString)")
    defer { try? fm.removeItem(at: tempOldSnapshot) }

    try fm.createDirectory(at: tempOldSnapshot, withIntermediateDirectories: true)
    try await GitClient.archiveExtract(
      repoRoot: repoRootURL,
      treeHash: oldSignedTreeHash,
      destinationURL: tempOldSnapshot
    )

    let oldManifest = try ManifestParser.load(
      from: tempOldSnapshot.appendingPathComponent("manifest.json"),
      expectedId: input.id
    )
    let newManifest = try ManifestParser.load(
      from: ruleDir.appendingPathComponent("manifest.json"),
      expectedId: input.id
    )

    try ManifestValidator.validateStructure(
      ruleDirectory: ruleDir,
      manifest: newManifest,
      repoRoot: repoRootURL,
      registry: registry,
      isFixtureMode: false
    )

    let context = WeakeningContext(
      input: input,
      oldManifest: oldManifest,
      newManifest: newManifest,
      ruleDir: ruleDir,
      tempOldSnapshot: tempOldSnapshot,
      repoRootURL: repoRootURL,
      registry: registry,
      oldSignedTreeHash: oldSignedTreeHash,
      env: env
    )

    // Check weakening
    try await checkWeakening(context: context)

    // Verify fixtures
    try await verifyFixtures(
      ruleId: input.id,
      ruleDir: ruleDir,
      manifest: newManifest,
      languages: registry.languages,
      env: env
    )

    // Save and commit
    try await saveAndCommitUpdate(
      input: input,
      repoRootURL: repoRootURL,
      oldSignedTreeHash: oldSignedTreeHash,
      registry: &registry
    )
  }

  private static func checkWeakening(context: WeakeningContext) async throws {
    let runner = RuleRunner(environment: context.env)

    var oldCases: [FixtureCase] = []
    for target in context.oldManifest.targets {
      if let cases = try? FixtureDiscoverer.discover(
        ruleDirectory: context.tempOldSnapshot,
        target: target,
        manifestCodes: context.oldManifest.codes
      ) {
        oldCases.append(contentsOf: cases)
      }
    }

    var newCases: [FixtureCase] = []
    for target in context.newManifest.targets {
      let cases = try FixtureDiscoverer.discover(
        ruleDirectory: context.ruleDir,
        target: target,
        manifestCodes: context.newManifest.codes
      )
      newCases.append(contentsOf: cases)
    }

    var weakening = WeakeningDetector.detect(
      ruleId: context.input.id,
      oldManifest: context.oldManifest,
      newManifest: context.newManifest,
      oldCases: oldCases,
      newCases: newCases
    )

    let (oldV, newV) = await countRepoViolations(context: context, runner: runner)

    if newV < oldV {
      var updated = weakening.items
      updated.append(
        WeakeningItem(
          severity: .red,
          category: "repoViolationsDropped",
          message: "Repo violations dropped from \(oldV) to \(newV) for unchanged product code."
        )
      )
      weakening = WeakeningReport(ruleId: context.input.id, items: updated)
    }

    if weakening.hasRedFlags {
      print("\n🔴 WEAKENING DETECTED in invariant '\(context.input.id)':")
      for item in weakening.items where item.severity == .red {
        print("  ✗ [\(item.category)] \(item.message)")
      }

      var isConfirmed = context.input.confirm || (context.input.confirmId == context.input.id)
      if !isConfirmed && TerminalPrompt.isInteractive {
        let typed = TerminalPrompt.prompt(
          question: "\nTo confirm this weakening, please type the rule id '\(context.input.id)'")
        if typed == context.input.id {
          isConfirmed = true
        }
      }

      if !isConfirmed {
        throw UpdateRuleWorkflowError.weakeningBlocked(context.input.id)
      }
    }

    if weakening.hasGreenFlags {
      print("\n🟢 Legitimate additions:")
      for item in weakening.items where item.severity == .green {
        print("  ✓ [\(item.category)] \(item.message)")
      }
    }
  }

  private static func countRepoViolations(context: WeakeningContext, runner: RuleRunner) async -> (Int, Int) {
    var oldRepoViolationsCount = 0
    var newRepoViolationsCount = 0

    for target in context.newManifest.targets {
      guard let scope = context.newManifest.scope[target] else { continue }
      let scopedFiles = ManifestValidator.resolveScopedFiles(repoRoot: context.repoRootURL, scope: scope)

      let oldReq = RuleRequest(
        mode: "repo",
        repoRoot: context.repoRootURL.path,
        ruleDir: context.tempOldSnapshot.path,
        files: scopedFiles.map { $0.path },
        languages: context.registry.languages
      )
      let newReq = RuleRequest(
        mode: "repo",
        repoRoot: context.repoRootURL.path,
        ruleDir: context.ruleDir.path,
        files: scopedFiles.map { $0.path },
        languages: context.registry.languages
      )

      let oldRes =
        (try? await runner.execute(
          target: target,
          ruleDirectory: context.tempOldSnapshot,
          ruleTreeHash: context.oldSignedTreeHash,
          request: oldReq,
          engineVersion: EngineVersion.current
        )) ?? []

      let newRes =
        (try? await runner.execute(
          target: target,
          ruleDirectory: context.ruleDir,
          ruleTreeHash: "update_preview",
          request: newReq,
          engineVersion: EngineVersion.current
        )) ?? []

      oldRepoViolationsCount += oldRes.count
      newRepoViolationsCount += newRes.count
    }
    return (oldRepoViolationsCount, newRepoViolationsCount)
  }

  private static func verifyFixtures(
    ruleId: String,
    ruleDir: URL,
    manifest: RuleManifest,
    languages: LanguagesConfig,
    env: SystemEnvironment
  ) async throws {
    let runner = RuleRunner(environment: env)
    print("\nVerifying fixtures for '\(ruleId)'...")

    for target in manifest.targets {
      let cases = try FixtureDiscoverer.discover(ruleDirectory: ruleDir, target: target, manifestCodes: manifest.codes)
      for fixtureCase in cases {
        let req = RuleRequest(
          mode: "fixture",
          repoRoot: fixtureCase.rootURL.path,
          ruleDir: ruleDir.path,
          files: fixtureCase.files.map { $0.path },
          languages: languages
        )
        let violations = try await runner.execute(
          target: target,
          ruleDirectory: ruleDir,
          ruleTreeHash: "update_preview",
          request: req,
          engineVersion: EngineVersion.current
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
          throw UpdateRuleWorkflowError.fixtureFailed(
            "Fixture '\(fixtureCase.id)' failed: expected 0, got \(violations.count)")
        } else if !fixtureCase.isShouldPass && expected != reported {
          throw UpdateRuleWorkflowError.fixtureFailed("Fixture '\(fixtureCase.id)' mismatch")
        }
      }
    }
    print("✓ All fixtures green.")
  }

  private static func saveAndCommitUpdate(
    input: Input,
    repoRootURL: URL,
    oldSignedTreeHash: String,
    registry: inout Registry
  ) async throws {
    let newTreeHash = try await FingerprintEngine.computeFingerprint(repoRoot: repoRootURL, ruleId: input.id)
    guard newTreeHash != oldSignedTreeHash else {
      print("Notice: No changes detected. Rule '\(input.id)' is already at tree \(newTreeHash).")
      return
    }

    guard let keyURL = await SigningKeyWorkflow.resolveOrPrompt(customPath: input.keyPath) else {
      throw UpdateRuleWorkflowError.noSigningKey
    }

    registry.version += 1
    registry.rules[input.id] = newTreeHash

    print("Signing registry v\(registry.version) with \(keyURL.lastPathComponent)...")
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
        "invariants/rules/\(input.id)",
      ],
      message: "Update invariant '\(input.id)' (registry v\(registry.version))"
    )

    print("✓ Rule '\(input.id)' updated to \(newTreeHash) in registry v\(registry.version).")
  }
}

private struct WeakeningContext {
  let input: UpdateRuleWorkflow.Input
  let oldManifest: RuleManifest
  let newManifest: RuleManifest
  let ruleDir: URL
  let tempOldSnapshot: URL
  let repoRootURL: URL
  let registry: Registry
  let oldSignedTreeHash: String
  let env: SystemEnvironment
}

package enum UpdateRuleWorkflowError: LocalizedError, Sendable {
  case notActive(String)
  case directoryMissing(String)
  case weakeningBlocked(String)
  case fixtureFailed(String)
  case noSigningKey

  package var errorDescription: String? {
    switch self {
    case .notActive(let id):
      return "Rule '\(id)' is not currently active. Use 'invariants add \(id)' to activate it."
    case .directoryMissing(let path):
      return "Working tree directory missing at \(path)"
    case .weakeningBlocked(let id):
      return "Update blocked by weakening guard. Pass --confirm-id \(id) or type rule id to confirm."
    case .fixtureFailed(let reason):
      return reason
    case .noSigningKey:
      return "No signing key found. Run 'invariants key generate' or specify --key <path>."
    }
  }
}
