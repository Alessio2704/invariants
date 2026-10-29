import Foundation
import Testing

@testable import Core
@testable import Managers
@testable import Terminal
@testable import Workflows

@Suite("Security & Architecture Drift: Cache Poisoning, Lifecycle & Runtime Bugs", .serialized, .tags(.driftAudit))
struct DriftAndLifecycleAttackTests {

  @Test("DRIFT-01: kit-ts package.json typescript@7.0.2 requires hand-edited version.cjs")
  func drift01_cleanTs7PackageLacksTranspileModuleAndEnsureCompatFails() throws {
    let repoRoot = (try? RepoLocator.discover()) ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let versionCjsURL = repoRoot.appendingPathComponent("kits/kit-ts/node_modules/typescript/lib/version.cjs")

    // In a clean npm ci install of typescript@7.0.2, version.cjs exports ONLY:
    // module.exports = { version: "7.0.2", versionMajorMinor: "7.0" };
    // On this machine, version.cjs was manually hand-edited to load /opt/homebrew/...
    if FileManager.default.fileExists(atPath: versionCjsURL.path) {
      let content = try versionCjsURL.readUTF8()
      let containsHandPatch = content.contains("/opt/homebrew") || content.contains("tsCompat")
      #expect(
        !containsHandPatch,
        "Drift DRIFT-01 confirmed: node_modules/typescript/lib/version.cjs is hand-patched to /opt/homebrew!"
      )
    }

    // loader.ts relies on rawTs.transpileModule which does not exist in standard typescript@7.0.2
    let loaderURL = repoRoot.appendingPathComponent("kits/kit-ts/src/loader.ts")
    let loaderContent = try loaderURL.readUTF8()
    let callsTranspileModuleOnRawTs = loaderContent.contains("rawTs.transpileModule")
    #expect(
      !callsTranspileModuleOnRawTs,
      "Drift DRIFT-01 confirmed: loader.ts calls rawTs.transpileModule which does not exist in typescript@7.0.2 export!"
    )
  }

  @Test("DRIFT-02a: TestRuleWorkflow hardcodes ruleTreeHash 'working_tree', causing cross-rule cache poisoning")
  func drift02a_testRuleWorkflowWorkingTreeCacheCollisionAcrossRules() async throws {
    let fixture = try await AuditProjectFixture()
    try await fixture.verifyBaseline()

    // 1. Run TestRuleWorkflow on no-print-in-app
    // This compiles no-print-in-app into ~/Library/Caches/invariants/rules/<version>/working_tree/.build/debug/RuleExecutable
    let passed1 = try await fixture.run {
      try await TestRuleWorkflow.execute(ruleId: "no-print-in-app")
    }
    #expect(passed1)

    // 2. Now run TestRuleWorkflow on no-debug-dump (a completely different rule that checks dump())
    // In TestRuleWorkflow.swift:85:
    // let binaryPath = try await runner.ensureCompiled(ruleId: ruleId, ruleTreeHash: "working_tree", ...)
    // Because the cache directory for "working_tree" already exists from rule 1,
    // ensureCompiled returns the cached binary of NO-PRINT instead of compiling NO-DUMP!
    // As a result, no-debug-dump executes no-print-in-app's binary and fails its should_fail fixture!
    let passed2 = try await fixture.run {
      try await TestRuleWorkflow.execute(ruleId: "no-debug-dump")
    }

    #expect(
      passed2,
      "Drift DRIFT-02a confirmed: no-debug-dump executed cached binary from no-print-in-app due to 'working_tree' cache collision!"
    )
  }

  @Test("DRIFT-02b: CheckManager draft rules collide on hardcoded cache key 'draft'")
  func drift02b_checkManagerDraftRuleCacheCollision() async throws {
    let fixture = try await AuditProjectFixture()
    try await fixture.verifyBaseline()

    // Create 2 draft rules with distinct violation codes
    let fm = FileManager.default
    let draft1Dir = fixture.repoURL.appendingPathComponent("invariants/rules/draft-rule-1")
    let draft2Dir = fixture.repoURL.appendingPathComponent("invariants/rules/draft-rule-2")

    try fm.createDirectory(at: draft1Dir.appendingPathComponent("should_pass/swift"), withIntermediateDirectories: true)
    try fm.createDirectory(at: draft1Dir.appendingPathComponent("should_fail/swift"), withIntermediateDirectories: true)
    try fm.createDirectory(at: draft2Dir.appendingPathComponent("should_pass/swift"), withIntermediateDirectories: true)
    try fm.createDirectory(at: draft2Dir.appendingPathComponent("should_fail/swift"), withIntermediateDirectories: true)

    let manifest1: [String: Any] = [
      "id": "draft-rule-1", "summary": "Draft 1", "targets": ["swift"],
      "scope": ["swift": ["main": ["include": ["Sources/**/*.swift"]]]], "codes": ["DRAFT-01": "D1"],
    ]
    let manifest2: [String: Any] = [
      "id": "draft-rule-2", "summary": "Draft 2", "targets": ["swift"],
      "scope": ["swift": ["main": ["include": ["Sources/**/*.swift"]]]], "codes": ["DRAFT-02": "D2"],
    ]

    try JSONSerialization.data(withJSONObject: manifest1).write(to: draft1Dir.appendingPathComponent("manifest.json"))
    try JSONSerialization.data(withJSONObject: manifest2).write(to: draft2Dir.appendingPathComponent("manifest.json"))

    let rule1Src = """
      import InvariantKit
      @main struct DraftRule1: SwiftRule {
          func check(_ ctx: RuleContext) throws(RuleError) -> [Violation] {
              let s = SourceFileCollection(files: ctx.files, repoRoot: ctx.repoRoot)
              return s.calls(named: "d1").violations(code: "DRAFT-01", message: { _ in "D1" }, fix: "ok")
          }
      }
      """
    let rule2Src = """
      import InvariantKit
      @main struct DraftRule2: SwiftRule {
          func check(_ ctx: RuleContext) throws(RuleError) -> [Violation] {
              let s = SourceFileCollection(files: ctx.files, repoRoot: ctx.repoRoot)
              return s.calls(named: "d2").violations(code: "DRAFT-02", message: { _ in "D2" }, fix: "ok")
          }
      }
      """

    try rule1Src.write(to: draft1Dir.appendingPathComponent("rule.swift"), atomically: true, encoding: .utf8)
    try rule2Src.write(to: draft2Dir.appendingPathComponent("rule.swift"), atomically: true, encoding: .utf8)

    try "struct Clean1 {}\n".write(
      to: draft1Dir.appendingPathComponent("should_pass/swift/case1.swift"), atomically: true, encoding: .utf8)
    try "func bad1() { d1() } // expect: DRAFT-01\n".write(
      to: draft1Dir.appendingPathComponent("should_fail/swift/case1.swift"), atomically: true, encoding: .utf8)

    try "struct Clean2 {}\n".write(
      to: draft2Dir.appendingPathComponent("should_pass/swift/case1.swift"), atomically: true, encoding: .utf8)
    try "func bad2() { d2() } // expect: DRAFT-02\n".write(
      to: draft2Dir.appendingPathComponent("should_fail/swift/case1.swift"), atomically: true, encoding: .utf8)

    // In CheckManager.swift:325:
    // ruleTreeHash: "draft"
    // Both draft rules are compiled under the SAME cache key "draft".
    // The second draft rule runs the first draft rule's binary!
    let report = try await fixture.run {
      try await CheckManager.runPipeline()
    }

    let draftItems = report.rules.filter { $0.statusKind == .draft }
    let allDraftsPassed =
      draftItems.count == 2
      && draftItems.allSatisfy {
        $0.draftPassedFixtures == $0.draftTotalFixtures && ($0.draftTotalFixtures ?? 0) > 0
      }

    #expect(
      allDraftsPassed,
      "Drift DRIFT-02b confirmed: draft rules collided on cache key 'draft'!"
    )
  }

  @Test("DRIFT-03a: Key rotation followed by signers rotate fails with unauthorizedSigner")
  func drift03a_keyRotateFollowedBySignersRotateFailsWithUnauthorizedSigner() async throws {
    let fixture = try await AuditProjectFixture()
    try await fixture.verifyBaseline()

    // Simulate `invariants key rotate`:
    // It creates a backup of ownerKey at ownerKey.bak-<timestamp>
    // and generates a new key at ownerKey
    let fm = FileManager.default
    let backupKey = fixture.ownerKey.deletingLastPathComponent().appendingPathComponent("owner_p256.bak-123456789")
    try fm.copyItem(at: fixture.ownerKey, to: backupKey)
    try fm.copyItem(
      at: fixture.ownerKey.appendingPathExtension("pub"),
      to: backupKey.appendingPathExtension("pub")
    )

    // Overwrite ownerKey with brand new key (not yet in allowed_signers)
    let newKeyURL = fixture.ownerKey
    try fm.removeItem(at: newKeyURL)
    try fm.removeItem(at: newKeyURL.appendingPathExtension("pub"))
    try SigningClient.generateThrowawayKey(at: newKeyURL)
    let newPub = try newKeyURL.appendingPathExtension("pub").readTrimmedUTF8()

    // Now run SignersWorkflow.rotate
    // In SignersWorkflow.swift:116:
    // let session = try SigningSession.authorize(customPath: signingKey)
    // This checks whether the NEW key at ownerKey is in allowed_signers!
    // Since it's not in allowed_signers yet, it immediately throws unauthorizedSigner
    // before detectOldBackupKey is ever reached!
    await #expect(
      throws: Never.self,
      "Drift DRIFT-03a confirmed: SignersWorkflow.rotate failed with unauthorizedSigner on rotated key!"
    ) {
      try await fixture.run {
        try await SignersWorkflow.rotate(
          old: fixture.ownerPub,
          new: newPub,
          sunset: 86400,
          signingKey: newKeyURL.path
        )
      }
    }
  }

  @Test("DRIFT-03b: SignersWorkflow.add ignores identity parameter for principal and rotate drops principals")
  func drift03b_signersAddIgnoresIdentityPrincipalAndRotateDropsPrincipals() async throws {
    let fixture = try await AuditProjectFixture()
    try await fixture.verifyBaseline()

    // In SignersWorkflow.swift:49-60:
    // SignersWorkflow.add(key: coworkerPub, identity: "coworker@acme.com", signingKey: ownerKey)
    // hardcodes: principal: "*" and appends identity as a comment!
    try await fixture.run {
      try await SignersWorkflow.add(
        key: fixture.coworkerPub,
        identity: "coworker@acme.com",
        signingKey: fixture.ownerKey.path
      )
    }

    let signersURL = fixture.repoURL.appendingPathComponent("invariants/allowed_signers")
    let file = try AllowedSignersFile.read(from: signersURL)
    let coworkerEntry = file.entries.first { $0.matches(keyString: fixture.coworkerPub) }

    #expect(
      coworkerEntry?.principals == ["coworker@acme.com"],
      "Drift DRIFT-03b confirmed: SignersWorkflow.add hardcoded principal '*' instead of 'coworker@acme.com'!"
    )
  }

  @Test("DRIFT-05: SubprocessRunner misreports every crashing process as processTimedOut")
  func drift05_crashingRuleProcessMisreportedAsRuleTimedOut() async throws {
    // Run a command that immediately crashes with SIGABRT with a 60-second timeout.
    // In SubprocessRunner.swift:137:
    // if !process.isRunning && process.terminationReason == .uncaughtSignal {
    //     throw SystemError.processTimedOut(...)
    // }
    // It does not check if monitorTask timed out!
    // Every crashed process is misreported as having timed out after 60s!
    do {
      _ = try await SubprocessRunner.run(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "kill -ABRT $$"],
        timeoutSeconds: 60.0
      )
      #expect(Bool(false), "Expected crashing process to throw, but it succeeded")
    } catch let SystemError.processTimedOut(command, timeout) {
      // DRIFT-05 confirmed: It misreported a crashing process (SIGABRT) as a timeout!
      #expect(
        Bool(false),
        "Drift DRIFT-05 confirmed: SubprocessRunner misreported immediate SIGABRT crash as processTimedOut(\(command), \(timeout)s)!"
      )
    } catch {
      // Secure behavior: When fixed, it should report a process failure/crash, not processTimedOut
    }
  }

  @Test("DRIFT-07: SelfUpdateWorkflow stages kits/kit-ts without running npm ci to install node_modules")
  func drift07_selfUpdateStagesTsKitWithoutNodeModules() throws {
    let repoRoot = (try? RepoLocator.discover()) ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let workflowURL = repoRoot.appendingPathComponent("Sources/Workflows/SelfUpdateWorkflow.swift")
    let workflowContent = try workflowURL.readUTF8()

    // In SelfUpdateWorkflow.swift:115-127:
    // It copies kits/ into stageDir/kits, but NEVER runs npm ci / npm install!
    // Since node_modules is gitignored, self-update produces an installation without kit-ts runtime dependencies!
    let runsNpmInSelfUpdate = workflowContent.contains("npm ci") || workflowContent.contains("npm install")

    #expect(
      runsNpmInSelfUpdate,
      "Drift DRIFT-07 confirmed: SelfUpdateWorkflow stages kit-ts without running npm ci/install to populate node_modules!"
    )
  }

  @Test("DRIFT-08a: Default scaffolded rule flags its own should_fail fixture in repo check")
  func drift08a_defaultScaffoldedRuleFlagsOwnShouldFailFixtureInRepoCheck() async throws {
    let fixture = try await AuditProjectFixture()
    try await fixture.verifyBaseline()

    // Scaffold a new rule with default scope (**/*.swift)
    try fixture.run {
      try NewRuleWorkflow.execute(id: "check-force-try", targets: [.swift])
    }

    let ruleDir = fixture.repoURL.appendingPathComponent("invariants/rules/check-force-try")
    let ruleSwift = """
      import InvariantKit
      @main struct CheckForceTryRule: SwiftRule {
          func check(_ ctx: RuleContext) throws(RuleError) -> [Violation] {
              let s = SourceFileCollection(files: ctx.files, repoRoot: ctx.repoRoot)
              return s.calls(named: "badCall").violations(code: "SAMPLE-01", message: { _ in "err" }, fix: "ok")
          }
      }
      """
    try ruleSwift.write(to: ruleDir.appendingPathComponent("rule.swift"), atomically: true, encoding: .utf8)
    try "func bad() { badCall(\"bad\") } // expect: SAMPLE-01\n".write(
      to: ruleDir.appendingPathComponent("should_fail/swift/case1.swift"), atomically: true, encoding: .utf8)
    try "struct CleanItem {}\n".write(
      to: ruleDir.appendingPathComponent("should_pass/swift/case1.swift"), atomically: true, encoding: .utf8)

    // Ensure add_preview cache is cleared to prevent cross-rule cache poisoning from other tests
    let fm = FileManager.default
    if let userCache = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
      let addPreviewCache = userCache.appendingPathComponent("invariants/rules/\(EngineVersion.current)/add_preview")
      try? fm.removeItem(at: addPreviewCache)
    }

    // Add and sign rule
    try await fixture.run {
      try await Terminal.withInteractiveSession {
        try await AddRuleWorkflow.execute(ruleId: "check-force-try", keyPath: fixture.ownerKey.path)
      }

      // CheckWorkflow.execute evaluates repo files against the rule.
      // Because universalIgnoredPaths does NOT ignore invariants/rules,
      // it scans invariants/rules/check-force-try/should_fail/case1.swift and reports a violation!
      let passed = try await CheckWorkflow.execute(json: false, prePush: false)
      #expect(
        passed,
        "Drift DRIFT-08a confirmed: rule flagged its own should_fail fixture during repo check!"
      )
    }
  }

  @Test("DRIFT-08b: FixtureDiscoverer throws EISDIR on folder fixture containing subdirectories")
  func drift08b_folderFixtureWithNestedSubdirectoryThrowsDirectoryReadError() throws {
    let fixtureDir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "folder_fixture_\(UUID().uuidString)")
    let failDir = fixtureDir.appendingPathComponent("should_fail/swift/case_folder")
    let subDir = failDir.appendingPathComponent("NestedSubdir")
    try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixtureDir) }

    try "func test() {} // expect: TEST-01\n".write(
      to: subDir.appendingPathComponent("Test.swift"), atomically: true, encoding: .utf8)

    // FixtureDiscoverer.parseFolderCase iterates failDir without checking isRegularFile!
    // It passes `NestedSubdir` to AnnotationParser.extractExpectations, which throws EISDIR!
    #expect(
      throws: Never.self,
      "Drift DRIFT-08b confirmed: FixtureDiscoverer threw error trying to read nested folder as file!"
    ) {
      _ = try FixtureDiscoverer.discover(
        ruleDirectory: fixtureDir,
        target: .swift,
        manifestCodes: ["TEST-01": "desc"]
      )
    }
  }

  @Test("DRIFT-08c: WeakeningDetector traps on multi-target rules with duplicate folder fixture IDs")
  func drift08c_weakeningDetectorTrapsOnMultiTargetSameNamedFolderFixtures() throws {
    let repoRoot = (try? RepoLocator.discover()) ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let detectorURL = repoRoot.appendingPathComponent("Sources/Core/Weakening/WeakeningDetector.swift")
    let content = try detectorURL.readUTF8()

    // Lines 103 & 132 crash with Fatal error: Duplicate keys found whenever a multi-target rule has
    // same-named fixture cases across targets (e.g. case1 in swift and case1 in ts).
    let usesUnsafeUniqueKeys = content.contains("Dictionary(uniqueKeysWithValues:")
    let usesDisambiguatedKey = content.contains("uniquingKeysWith:") || content.contains(".target")

    #expect(
      !usesUnsafeUniqueKeys && usesDisambiguatedKey,
      "Drift DRIFT-08c confirmed: WeakeningDetector uses Dictionary(uniqueKeysWithValues:) crashing on multi-target rules!"
    )
  }

  @Test("DRIFT-09a: RawTerminalSession.readKey returns .unknown on EOF, causing infinite 100% CPU loop")
  func drift09a_rawTerminalReadKeySpinsInfinitelyOnStdinEOF() async throws {
    // When stdin hits EOF (e.g. non-interactive subshell or piped input),
    // read(STDIN_FILENO, &buffer, 1) returns 0 (EOF).
    // RawTerminalSession.readKey maps this to .unknown.
    // promptSelection runs:
    // while true { let key = session.readKey(); switch key { ... default: continue } }
    // which spins in an infinite loop at 100% CPU!
    let session = RawTerminalSession()
    let keyAtEOF = session.readKey()

    // Secure behavior: EOF must be recognized as .eof or throw, never silently mapped to .unknown
    #expect(
      keyAtEOF != .unknown,
      "Drift DRIFT-09a confirmed: readKey returned .unknown on EOF, causing infinite loop in interactive prompts!"
    )
  }

  @Test("DRIFT-09b: RuleContext leaks fixture_index_* and invariants_db_* in /tmp without cleanup")
  func drift09b_swiftKitRuleContextLeaksTempIndexDirectories() throws {
    let repoRoot = (try? RepoLocator.discover()) ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let ruleContextURL = repoRoot.appendingPathComponent(
      "kits/kit-swift/Sources/InvariantKit/RuleContext.swift"
    )
    let content = try ruleContextURL.readUTF8()

    // In RuleContext.swift:159-182:
    // It creates fixture_index_<UUID>, fixture_db_<UUID>, and invariants_db_<UUID> in /tmp
    // but contains zero deinit or defer cleanup logic, leaking directories indefinitely.
    let createsTempDirectories = content.contains("fixture_index_") || content.contains("fixture_db_")
    let hasCleanup = content.contains("deinit") || content.contains("removeItem")

    #expect(
      !createsTempDirectories || hasCleanup,
      "Drift DRIFT-09b confirmed: RuleContext creates temporary fixture index/db directories in /tmp without cleanup!"
    )
  }
}
