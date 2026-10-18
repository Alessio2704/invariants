import ArgumentParser
import Foundation
import InvariantCore

private struct CheckContext {
  let repoRootURL: URL
  let registry: Registry
  let ruleRunner: RuleRunner
}

private struct ActiveRuleContext {
  let ruleId: String
  let manifest: RuleManifest
  let signedTreeHash: String
  let workingTreeHash: String?
  let isModified: Bool
  let tempSnapshotDir: URL
}

struct CheckCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "check",
    abstract: "Execute the complete invariant enforcement pipeline."
  )

  @Option(name: .long, help: "Git hook stage: pre-commit or pre-push.")
  var stage: String?

  @Flag(name: .long, help: "Emit output in machine-readable JSON format.")
  var json: Bool = false

  func run() async throws {
    let repoRootURL = try RepoLocator.requireRepoRoot()
    let env = SystemEnvironment.standard

    let registry = try await verifyRegistry(repoRootURL: repoRootURL)
    try await verifyFloor(repoRootURL: repoRootURL, registry: registry)

    let context = CheckContext(
      repoRootURL: repoRootURL,
      registry: registry,
      ruleRunner: RuleRunner(environment: env)
    )

    let activeItems = try await checkActiveRules(context: context)
    let draftItems = await discoverDraftRules(context: context)

    let report = CheckReport(
      registryVersion: registry.version,
      engineVersion: EngineVersion.current,
      rules: activeItems + draftItems
    )

    outputReport(report)

    if report.hasProblems {
      throw ExitCode(1)
    }
  }
}

extension CheckCommand {
  private func verifyRegistry(repoRootURL: URL) async throws -> Registry {
    do {
      return try await RegistryManager.loadAndVerify(
        repoRoot: repoRootURL,
        installedEngineVersion: EngineVersion.current
      )
    } catch let regErr {
      switch regErr {
      case .signatureInvalid(let msg):
        fputs("✗ invariants check: signature invalid — \(msg)\n", stderr)
        throw ExitCode(70)
      case .signatureNotFound(let url):
        fputs("✗ invariants check: signature not found at \(url.path)\n", stderr)
        throw ExitCode(70)
      case .engineVersionMismatch(let req, let inst):
        fputs("✗ invariants check: engine version mismatch (installed \(inst), requires \(req))\n", stderr)
        throw ExitCode(70)
      default:
        fputs("✗ invariants check: \(regErr)\n", stderr)
        throw ExitCode(1)
      }
    }
  }

  private func verifyFloor(
    repoRootURL: URL,
    registry: Registry
  ) async throws {
    do {
      _ = try await FloorGuard.checkHistory(repoRoot: repoRootURL, currentVersion: registry.version)

      let lockURL = RegistryManager.registryURL(repoRoot: repoRootURL)
      let sigURL = RegistryManager.signatureURL(repoRoot: repoRootURL)
      try await FloorGuard.checkSignerAncestry(
        repoRoot: repoRootURL,
        currentRegistry: registry,
        lockURL: lockURL,
        sigURL: sigURL
      )

      if stage == "pre-push" {
        let stdinData = FileHandle.standardInput.readDataToEndOfFile()
        let pushedRefs = String(bytes: stdinData, encoding: .utf8) ?? ""
        try await FloorGuard.checkNoRewrite(
          repoRoot: repoRootURL,
          pushedRefsInput: pushedRefs,
          defaultBranch: registry.defaultBranch
        )
      }
    } catch let floorErr {
      switch floorErr {
      case .unauthorizedSigner(let v, let pv):
        fputs(
          "✗ invariants floor check failed: Version \(v) is not signed by an authorized signer from parent version \(pv).\n",
          stderr
        )
        throw ExitCode(70)
      default:
        fputs("✗ invariants floor check failed: \(floorErr)\n", stderr)
        throw ExitCode(1)
      }
    }
  }

  private func checkActiveRules(context: CheckContext) async throws -> [RuleReportItem] {
    var items: [RuleReportItem] = []
    let sortedRuleKeys = context.registry.rules.keys.sorted()
    for ruleId in sortedRuleKeys {
      guard let signedTreeHash = context.registry.rules[ruleId] else { continue }
      let item = await checkSingleActiveRule(
        ruleId: ruleId,
        signedTreeHash: signedTreeHash,
        context: context
      )
      items.append(item)
    }
    return items
  }

  private func checkSingleActiveRule(
    ruleId: String,
    signedTreeHash: String,
    context: CheckContext
  ) async -> RuleReportItem {
    let fileManager = FileManager.default
    let ruleDir = context.repoRootURL.appendingPathComponent("invariants/rules/\(ruleId)")

    guard fileManager.fileExists(atPath: ruleDir.path) else {
      return RuleReportItem(ruleId: ruleId, statusKind: .missing, message: "Rule directory missing on disk")
    }

    let workingTreeHash = try? await FingerprintEngine.computeFingerprint(
      repoRoot: context.repoRootURL,
      ruleId: ruleId
    )
    let isModified = (workingTreeHash != signedTreeHash)

    let tempSnapshotDir = fileManager.temporaryDirectory.appendingPathComponent(
      "signed_snapshot_\(ruleId)_\(UUID().uuidString)")
    defer {
      try? fileManager.removeItem(at: tempSnapshotDir)
    }

    do {
      try fileManager.createDirectory(at: tempSnapshotDir, withIntermediateDirectories: true)
      try await GitClient.archiveExtract(
        repoRoot: context.repoRootURL,
        treeHash: signedTreeHash,
        destinationURL: tempSnapshotDir
      )
    } catch {
      return RuleReportItem(
        ruleId: ruleId,
        statusKind: .broken,
        message: "Failed to extract signed snapshot tree \(signedTreeHash): \(error)"
      )
    }

    let manifestURL = tempSnapshotDir.appendingPathComponent("manifest.json")
    let manifest: RuleManifest
    do {
      manifest = try ManifestParser.load(from: manifestURL, expectedId: ruleId)
    } catch {
      return RuleReportItem(
        ruleId: ruleId, statusKind: .broken, message: "manifest.json invalid in signed snapshot: \(error)")
    }

    do {
      try ManifestValidator.validateStructure(
        ruleDirectory: tempSnapshotDir,
        manifest: manifest,
        repoRoot: context.repoRootURL,
        registry: context.registry,
        isFixtureMode: false
      )
    } catch {
      return RuleReportItem(ruleId: ruleId, statusKind: .broken, message: "Signed manifest validation failed: \(error)")
    }

    if let fixtureFailure = await runSignedFixtures(
      manifest: manifest,
      signedTreeHash: signedTreeHash,
      tempSnapshotDir: tempSnapshotDir,
      context: context
    ) {
      return RuleReportItem(ruleId: ruleId, statusKind: .broken, message: fixtureFailure)
    }

    let ruleCtx = ActiveRuleContext(
      ruleId: ruleId,
      manifest: manifest,
      signedTreeHash: signedTreeHash,
      workingTreeHash: workingTreeHash,
      isModified: isModified,
      tempSnapshotDir: tempSnapshotDir
    )
    return await executeRepoEnforcement(ruleCtx: ruleCtx, context: context)
  }

  private func runSignedFixtures(
    manifest: RuleManifest,
    signedTreeHash: String,
    tempSnapshotDir: URL,
    context: CheckContext
  ) async -> String? {
    let isCachedPass = await FixtureCache.shared.isCachedPass(
      engineVersion: EngineVersion.current,
      ruleTreeHash: signedTreeHash
    )
    if isCachedPass {
      return nil
    }

    for target in manifest.targets {
      do {
        let cases = try FixtureDiscoverer.discover(
          ruleDirectory: tempSnapshotDir,
          target: target,
          manifestCodes: manifest.codes
        )
        for fixtureCase in cases {
          let req = RuleRequest(
            mode: "fixture",
            repoRoot: fixtureCase.rootURL.path,
            ruleDir: tempSnapshotDir.path,
            files: fixtureCase.files.map { $0.path },
            project: context.registry.project
          )
          let violations: [ReportedViolation]
          do {
            violations = try await context.ruleRunner.execute(
              target: target,
              ruleDirectory: tempSnapshotDir,
              ruleTreeHash: signedTreeHash,
              request: req,
              engineVersion: EngineVersion.current
            )
          } catch let runnerErr {
            switch runnerErr {
            case .ruleCrashed(_, let stderr):
              return HarnessError.ruleCrashed(caseId: fixtureCase.id, message: stderr).description
            case .ruleHung:
              return HarnessError.ruleHung(caseId: fixtureCase.id).description
            default:
              return "Self-test runner error on '\(fixtureCase.id)': \(runnerErr)"
            }
          }

          if let error = fixtureCase.evaluateExpectations(reportedViolations: violations) {
            return error.description
          }

          do {
            try ManifestValidator.validateReportedViolations(manifest: manifest, violations: violations)
          } catch {
            return error.description
          }
        }
      } catch {
        return "Self-test error: \(error)"
      }
    }

    await FixtureCache.shared.recordPass(
      engineVersion: EngineVersion.current,
      ruleTreeHash: signedTreeHash
    )
    return nil
  }

  private func executeRepoEnforcement(
    ruleCtx: ActiveRuleContext,
    context: CheckContext
  ) async -> RuleReportItem {
    var repoViolations: [ReportedViolation] = []

    for target in ruleCtx.manifest.targets {
      guard let targetScope = ruleCtx.manifest.scope[target] else { continue }
      let scopedFiles = ManifestValidator.resolveScopedFiles(
        repoRoot: context.repoRootURL,
        scope: targetScope
      )

      let req = RuleRequest(
        mode: "repo",
        repoRoot: context.repoRootURL.path,
        ruleDir: ruleCtx.tempSnapshotDir.path,
        files: scopedFiles.map { $0.path },
        project: context.registry.project
      )

      do {
        let targetViolations = try await context.ruleRunner.execute(
          target: target,
          ruleDirectory: ruleCtx.tempSnapshotDir,
          ruleTreeHash: ruleCtx.signedTreeHash,
          request: req,
          engineVersion: EngineVersion.current
        )
        try ManifestValidator.validateReportedViolations(
          manifest: ruleCtx.manifest,
          violations: targetViolations
        )
        repoViolations.append(contentsOf: targetViolations)
      } catch {
        return RuleReportItem(
          ruleId: ruleCtx.ruleId,
          statusKind: .broken,
          message: "Rule enforcement error: \(error)"
        )
      }
    }

    if !repoViolations.isEmpty {
      return RuleReportItem(ruleId: ruleCtx.ruleId, statusKind: .violations, violations: repoViolations)
    }
    if ruleCtx.isModified {
      return RuleReportItem(
        ruleId: ruleCtx.ruleId,
        statusKind: .modified,
        signedHash: ruleCtx.signedTreeHash,
        currentHash: ruleCtx.workingTreeHash
      )
    }
    return RuleReportItem(ruleId: ruleCtx.ruleId, statusKind: .passed)
  }

  private func discoverDraftRules(context: CheckContext) async -> [RuleReportItem] {
    let fileManager = FileManager.default
    let rulesBaseDir = context.repoRootURL.appendingPathComponent("invariants/rules")
    guard let allDirs = try? fileManager.contentsOfDirectory(atPath: rulesBaseDir.path) else {
      return []
    }

    var draftItems: [RuleReportItem] = []
    for dirName in allDirs.sorted() where !context.registry.rules.keys.contains(dirName) && !dirName.hasPrefix(".") {
      let draftDir = rulesBaseDir.appendingPathComponent(dirName)
      var isDir: ObjCBool = false
      guard fileManager.fileExists(atPath: draftDir.path, isDirectory: &isDir), isDir.boolValue else { continue }

      let (draftPassed, draftTotal) = await evaluateDraftFixtures(
        draftDir: draftDir,
        dirName: dirName,
        context: context
      )
      draftItems.append(
        RuleReportItem(
          ruleId: dirName,
          statusKind: .draft,
          draftPassedFixtures: draftPassed,
          draftTotalFixtures: draftTotal
        ))
    }
    return draftItems
  }

  private func evaluateDraftFixtures(
    draftDir: URL,
    dirName: String,
    context: CheckContext
  ) async -> (Int, Int) {
    var draftPassed = 0
    var draftTotal = 0
    guard
      let manifest = try? ManifestParser.load(
        from: draftDir.appendingPathComponent("manifest.json"),
        expectedId: dirName
      )
    else {
      return (0, 0)
    }

    for target in manifest.targets {
      guard
        let cases = try? FixtureDiscoverer.discover(
          ruleDirectory: draftDir, target: target, manifestCodes: manifest.codes)
      else {
        continue
      }
      draftTotal += cases.count
      for fixtureCase in cases {
        let req = RuleRequest(
          mode: "fixture",
          repoRoot: fixtureCase.rootURL.path,
          ruleDir: draftDir.path,
          files: fixtureCase.files.map { $0.path },
          project: context.registry.project
        )
        if let res = try? await context.ruleRunner.execute(
          target: target,
          ruleDirectory: draftDir,
          ruleTreeHash: "draft",
          request: req,
          engineVersion: EngineVersion.current
        ) {
          if (fixtureCase.isShouldPass && res.isEmpty) || (!fixtureCase.isShouldPass && !res.isEmpty) {
            draftPassed += 1
          }
        }
      }
    }
    return (draftPassed, draftTotal)
  }

  private func outputReport(_ report: CheckReport) {
    if json {
      FileHandle.standardOutput.write(Data(ReportFormatter.formatJSON(report).utf8))
    } else {
      FileHandle.standardOutput.write(Data(ReportFormatter.formatText(report).utf8))
    }
  }
}
