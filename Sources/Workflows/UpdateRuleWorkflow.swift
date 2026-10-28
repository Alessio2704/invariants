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
    let repoRootURL = RepoLocator.current
    let env = SystemEnvironment.standard
    let fm = FileManager.default

    // 1. Authorize signing session upfront (fail-fast)
    let session = try SigningSession.authorize(customPath: input.keyPath)

    var registry = try await RegistryManager.loadAndVerify()

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
      registry: registry,
      isFixtureMode: false
    )

    let context = WeakeningContext(
      input: input,
      oldManifest: oldManifest,
      newManifest: newManifest,
      ruleDir: ruleDir,
      tempOldSnapshot: tempOldSnapshot,
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
      oldSignedTreeHash: oldSignedTreeHash,
      registry: &registry,
      session: session
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

    let (oldViolations, newViolations) = try await collectRepoViolations(context: context, runner: runner)
    let dropped = Set(oldViolations).subtracting(Set(newViolations))

    if !dropped.isEmpty {
      var updated = weakening.items
      let fileList = dropped.prefix(3).map { "\($0.file):\($0.line)" }.joined(separator: ", ")
      let extra = dropped.count > 3 ? " and \(dropped.count - 3) more" : ""
      let droppedSummary = "Existing repo violations dropped: \(dropped.count) violation(s) no longer detected"
      let locationSummary = "(\(fileList)\(extra)). Total: \(oldViolations.count) → \(newViolations.count)."
      updated.append(
        WeakeningItem(
          severity: .red,
          category: "repoViolationsDropped",
          message: "\(droppedSummary) \(locationSummary)"
        )
      )
      weakening = WeakeningReport(ruleId: context.input.id, items: updated)
    }

    if weakening.hasRedFlags {
      Terminal.line("")
      Terminal.error("WEAKENING DETECTED in invariant '\(context.input.id)':")
      for item in weakening.items where item.severity == .red {
        Terminal.item("[\(item.category)] \(item.message)")
      }

      var isConfirmed = context.input.confirm || (context.input.confirmId == context.input.id)
      if !isConfirmed {
        let typed = try TerminalPrompt.prompt(
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
      Terminal.line("")
      Terminal.success("Legitimate additions:")
      for item in weakening.items where item.severity == .green {
        Terminal.item("[\(item.category)] \(item.message)")
      }
    }
  }

  private static func collectRepoViolations(
    context: WeakeningContext,
    runner: RuleRunner
  ) async throws -> (oldViolations: [ReportedViolation], newViolations: [ReportedViolation]) {
    var oldViolations: [ReportedViolation] = []
    var newViolations: [ReportedViolation] = []

    let allTargets = Array(Set(context.oldManifest.targets).union(context.newManifest.targets)).sorted {
      $0.rawValue < $1.rawValue
    }
    let newTreeHash = (try? await FingerprintEngine.computeFingerprint(ruleId: context.input.id)) ?? "update_preview"

    for target in allTargets {
      // SEC-06c: Old violations must be evaluated against oldManifest.scope
      let isOldTarget = context.oldManifest.targets.contains(target)
      let oldScope = context.oldManifest.scope[target]
      if isOldTarget, let oldScope {
        let oldScopedFiles = ManifestValidator.resolveScopedFiles(scope: oldScope, target: target)
        if !oldScopedFiles.isEmpty {
          let oldReq = RuleRequest(
            mode: "repo",
            repoRoot: RepoLocator.current.path,
            ruleDir: context.tempOldSnapshot.path,
            files: oldScopedFiles.map { $0.path },
            languages: context.registry.languages
          )
          // SEC-06a: Do not swallow runner execution errors with try? ?? []
          let oldRes = try await runner.execute(
            target: target,
            ruleDirectory: context.tempOldSnapshot,
            ruleTreeHash: context.oldSignedTreeHash,
            request: oldReq
          )
          oldViolations.append(contentsOf: oldRes)
        }
      }

      // New violations evaluated against newManifest.scope
      let isNewTarget = context.newManifest.targets.contains(target)
      let newScope = context.newManifest.scope[target]
      if isNewTarget, let newScope {
        let newScopedFiles = ManifestValidator.resolveScopedFiles(scope: newScope, target: target)
        if !newScopedFiles.isEmpty {
          let newReq = RuleRequest(
            mode: "repo",
            repoRoot: RepoLocator.current.path,
            ruleDir: context.ruleDir.path,
            files: newScopedFiles.map { $0.path },
            languages: context.registry.languages
          )
          // SEC-06a: Do not swallow runner execution errors with try? ?? []
          let newRes = try await runner.execute(
            target: target,
            ruleDirectory: context.ruleDir,
            ruleTreeHash: newTreeHash,
            request: newReq
          )
          newViolations.append(contentsOf: newRes)
        }
      }
    }
    return (oldViolations, newViolations)
  }

  private static func verifyFixtures(
    ruleId: String,
    ruleDir: URL,
    manifest: RuleManifest,
    languages: LanguagesConfig,
    env: SystemEnvironment
  ) async throws {
    let runner = RuleRunner(environment: env)
    Terminal.line("")
    Terminal.info("Verifying fixtures for '\(ruleId)'...")
    let ruleTreeHash = (try? await FingerprintEngine.computeFingerprint(ruleId: ruleId)) ?? "update_\(ruleId)"

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
          ruleTreeHash: ruleTreeHash,
          request: req
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
    Terminal.success("All fixtures green.")
  }

  private static func saveAndCommitUpdate(
    input: Input,
    oldSignedTreeHash: String,
    registry: inout Registry,
    session: SigningSession
  ) async throws {
    let newTreeHash = try await FingerprintEngine.computeFingerprint(ruleId: input.id)
    guard newTreeHash != oldSignedTreeHash else {
      Terminal.info("Notice: No changes detected. Rule '\(input.id)' is already at tree \(newTreeHash).")
      return
    }

    registry.version += 1
    registry.rules[input.id] = newTreeHash

    Terminal.info("Signing registry v\(registry.version) with \(session.privateKeyURL.lastPathComponent)...")
    try await RegistryManager.saveAndSign(
      registry: registry,
      keyURL: session.privateKeyURL
    )

    try await GitClient.commit(
      paths: [
        "invariants/registry.lock",
        "invariants/registry.lock.sig",
        "invariants/rules/\(input.id)",
      ],
      message: "Update invariant '\(input.id)' (registry v\(registry.version))"
    )

    Terminal.success("Rule '\(input.id)' updated to \(newTreeHash) in registry v\(registry.version).")
  }
}

private struct WeakeningContext {
  let input: UpdateRuleWorkflow.Input
  let oldManifest: RuleManifest
  let newManifest: RuleManifest
  let ruleDir: URL
  let tempOldSnapshot: URL
  let registry: Registry
  let oldSignedTreeHash: String
  let env: SystemEnvironment
}

package enum UpdateRuleWorkflowError: LocalizedError, Sendable {
  case notActive(String)
  case directoryMissing(String)
  case weakeningBlocked(String)
  case fixtureFailed(String)

  package var errorDescription: String? {
    switch self {
    case .notActive(let id):
      return "Rule '\(id)' is not currently active. Use 'invariants rule add \(id)' to activate it."
    case .directoryMissing(let path):
      return "Working tree directory missing at \(path)"
    case .weakeningBlocked(let id):
      return "Update blocked by weakening guard. Pass --confirm-id \(id) or type rule id to confirm."
    case .fixtureFailed(let reason):
      return reason
    }
  }
}
