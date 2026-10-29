package import Core
package import Foundation

private struct CheckContext {
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

/// Headless domain manager executing the complete invariant check pipeline.
/// Contains zero terminal formatting or CLI dependencies.
package enum CheckManager {
  /// Runs the complete check pipeline against the current repository and returns a CheckReport.
  package static func runPipeline(
    environment: SystemEnvironment = .standard
  ) async throws -> CheckReport {
    let registry = try await RegistryManager.loadAndVerify()

    _ = try await FloorGuard.checkHistory(currentVersion: registry.version)
    let isShallow = try await FloorGuard.checkSignerAncestry(currentRegistry: registry)

    let context = CheckContext(
      registry: registry,
      ruleRunner: RuleRunner(environment: environment)
    )

    let activeItems = try await checkActiveRules(context: context)
    let draftItems = await discoverDraftRules(context: context)

    return CheckReport(
      registryVersion: registry.version,
      rules: activeItems + draftItems,
      isShallowRepository: isShallow
    )
  }

  private static func checkActiveRules(context: CheckContext) async throws -> [RuleReportItem] {
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

  private static func checkSingleActiveRule(
    ruleId: String,
    signedTreeHash: String,
    context: CheckContext
  ) async -> RuleReportItem {
    let fileManager = FileManager.default
    let ruleDir = RepoLocator.current.appendingPathComponent("invariants/rules/\(ruleId)")

    guard fileManager.fileExists(atPath: ruleDir.path) else {
      return RuleReportItem(ruleId: ruleId, statusKind: .missing, message: "Rule directory missing on disk")
    }

    let workingTreeHash = try? await FingerprintEngine.computeFingerprint(
      ruleId: ruleId
    )
    let isModified = (workingTreeHash != signedTreeHash)

    do {
      return try await RuleSnapshotService.withSnapshot(
        treeHash: signedTreeHash,
        expectedId: ruleId
      ) { tempSnapshotDir, manifest in
        do {
          try ManifestValidator.validateStructure(
            ruleDirectory: tempSnapshotDir,
            manifest: manifest,
            registry: context.registry,
            isFixtureMode: false
          )
        } catch {
          return RuleReportItem(
            ruleId: ruleId, statusKind: .broken, message: "Signed manifest validation failed: \(error)")
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
    } catch {
      return RuleReportItem(
        ruleId: ruleId,
        statusKind: .broken,
        message: "Failed to extract or validate signed snapshot tree \(signedTreeHash): \(error)"
      )
    }
  }

  private static func runSignedFixtures(
    manifest: RuleManifest,
    signedTreeHash: String,
    tempSnapshotDir: URL,
    context: CheckContext
  ) async -> String? {
    let isCachedPass = await FixtureCache.shared.isCachedPass(
      ruleTreeHash: signedTreeHash
    )
    if isCachedPass {
      return nil
    }

    do {
      let outcome = try await FixtureExecutionService.evaluateFixtures(
        manifest: manifest,
        ruleDirectory: tempSnapshotDir,
        ruleTreeHash: signedTreeHash,
        ast: context.registry.ast,
        runner: context.ruleRunner
      )
      if let failure = outcome.failures.first {
        return failure.message
      }
    } catch {
      return "Self-test error: \(error)"
    }

    await FixtureCache.shared.recordPass(
      ruleTreeHash: signedTreeHash
    )
    return nil
  }

  private static func executeRepoEnforcement(
    ruleCtx: ActiveRuleContext,
    context: CheckContext
  ) async -> RuleReportItem {
    var repoViolations: [ReportedViolation] = []

    for target in ruleCtx.manifest.targets {
      guard let targetScopes = ruleCtx.manifest.scope[target] else { continue }
      let unitFilesURLs = ManifestValidator.resolveScopedFilesByUnit(
        scopes: targetScopes,
        target: target
      )
      var unitFiles: [String: [String]] = [:]
      var allFiles: [String] = []
      for (unit, urls) in unitFilesURLs {
        let paths = urls.map(\.path)
        unitFiles[unit] = paths
        allFiles.append(contentsOf: paths)
      }
      var seen = Set<String>()
      let dedupedFiles = allFiles.filter { seen.insert($0).inserted }

      let req = RuleRequest(
        mode: "repo",
        repoRoot: RepoLocator.current.path,
        ruleDir: ruleCtx.tempSnapshotDir.path,
        files: dedupedFiles,
        unitFiles: unitFiles,
        ast: context.registry.ast
      )

      do {
        let targetViolations = try await context.ruleRunner.execute(
          target: target,
          ruleDirectory: ruleCtx.tempSnapshotDir,
          ruleTreeHash: ruleCtx.signedTreeHash,
          request: req
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

  private static func discoverDraftRules(context: CheckContext) async -> [RuleReportItem] {
    let fileManager = FileManager.default
    let rulesBaseDir = RepoLocator.current.appendingPathComponent("invariants/rules")
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

  private static func evaluateDraftFixtures(
    draftDir: URL,
    dirName: String,
    context: CheckContext
  ) async -> (Int, Int) {
    let draftHash = (try? await FingerprintEngine.computeFingerprint(ruleId: dirName)) ?? "draft_\(dirName)"
    guard
      let manifest = try? ManifestParser.load(
        from: draftDir.appendingPathComponent("manifest.json"),
        expectedId: dirName
      )
    else {
      return (0, 0)
    }

    guard
      let outcome = try? await FixtureExecutionService.evaluateFixtures(
        manifest: manifest,
        ruleDirectory: draftDir,
        ruleTreeHash: draftHash,
        ast: context.registry.ast,
        runner: context.ruleRunner
      )
    else {
      return (0, 0)
    }

    return (outcome.passedCases, outcome.totalCases)
  }
}
