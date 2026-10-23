import Foundation
import Terminal
import Testing

@testable import Core
@testable import Managers
@testable import Workflows

/// Implementation of each discrete milestone step of the Acme Company journey.
enum AcmeSteps {
  // MARK: - Phase 1: Day 0 to Week 3 (v1 to v3)

  /// Day 0: Alice initializes the repository with Swift analysis configuration -> v1
  static func step_v01_day0_initRepository(ctx: AcmeJourneyContext) async throws {
    try await ctx.run {
      try await InitWorkflow.execute(
        input: .init(branch: "main", languages: [.swift], keyPath: ctx.aliceKey.path)
      )

      let reg = try await RegistryManager.loadAndVerify()
      #expect(reg.version == 1)
      #expect(reg.defaultBranch == "main")
      #expect(reg.languages[SwiftLanguage.self] != nil)
      #expect(reg.rules.isEmpty)

      let signers = try SignersManager.loadSigners()
      #expect(signers.count == 1)
      #expect(signers.first?.matches(keyString: ctx.alicePub) == true)
    }
  }

  /// Day 1: Alice creates, tests, and activates the first Swift invariant 'no-print-in-sources' -> v2
  static func step_v02_day1_addSwiftRule(ctx: AcmeJourneyContext) async throws {
    try await ctx.run {
      try NewRuleWorkflow.execute(id: "no-print-in-sources", targets: [.swift])

      let ruleDir = ctx.repoURL.appendingPathComponent("invariants/rules/no-print-in-sources")
      let manifestURL = ruleDir.appendingPathComponent("manifest.json")
      let manifestObj: [String: Any] = [
        "id": "no-print-in-sources",
        "summary": "Forbid print() calls in production sources",
        "targets": ["swift"],
        "scope": ["swift": ["include": ["Sources/**/*.swift"]]],
        "codes": ["NO-PRINT": "print() calls are forbidden in production code."],
      ]
      let manifestData = try JSONSerialization.data(
        withJSONObject: manifestObj, options: [.prettyPrinted, .sortedKeys])
      try manifestData.write(to: manifestURL)

      let ruleSwift = """
        import InvariantKit

        @main
        struct NoPrintInSourcesRule: SwiftRule {
            func check(_ ctx: RuleContext) throws(RuleError) -> [Violation] {
                let sources = SourceFileCollection(files: ctx.files, repoRoot: ctx.repoRoot)
                return sources.calls(named: "print").violations(
                    code: "NO-PRINT",
                    message: { _ in "print() calls are forbidden in production code." },
                    fix: "Logger.info(...)"
                )
            }
        }
        """
      try ruleSwift.write(
        to: ruleDir.appendingPathComponent("rule.swift"), atomically: true, encoding: .utf8)

      let passFixture = ruleDir.appendingPathComponent("should_pass/swift/case1.swift")
      try "struct CleanLogger { func log() {} }\n".write(
        to: passFixture, atomically: true, encoding: .utf8)

      let failFixture = ruleDir.appendingPathComponent("should_fail/swift/case1.swift")
      try "func leak() { print(\"debug\") } // expect: NO-PRINT\n".write(
        to: failFixture, atomically: true, encoding: .utf8)

      let testPassed = try await TestRuleWorkflow.execute(ruleId: "no-print-in-sources")
      #expect(testPassed)

      try await Terminal.withInteractiveSession {
        try await AddRuleWorkflow.execute(ruleId: "no-print-in-sources", keyPath: ctx.aliceKey.path)
      }

      let reg = try await RegistryManager.loadAndVerify()
      #expect(reg.version == 2)
      #expect(reg.rules["no-print-in-sources"] != nil)

      let floor = try await FloorGuard.checkHistory(currentVersion: reg.version)
      #expect(floor == 2)
      try await FloorGuard.checkSignerAncestry(currentRegistry: reg)
    }
  }

  /// Week 2: AI Agent attempts 4 distinct tampering vectors against v2; all are repelled -> v2 unchanged
  static func step_interlude_week2_agentAttacks(ctx: AcmeJourneyContext) async throws {
    try await ctx.run {
      let ruleDir = ctx.repoURL.appendingPathComponent("invariants/rules/no-print-in-sources")
      let manifestURL = ruleDir.appendingPathComponent("manifest.json")

      // 1. Manifest exclude tampering
      let tamperedManifestObj: [String: Any] = [
        "id": "no-print-in-sources",
        "summary": "Forbid print() calls in production sources",
        "targets": ["swift"],
        "scope": [
          "swift": [
            "include": ["Sources/**/*.swift"],
            "exclude": ["Sources/Debug/**"],
          ]
        ],
        "codes": ["NO-PRINT": "print() calls are forbidden in production code."],
      ]
      let tamperedManifestData = try JSONSerialization.data(
        withJSONObject: tamperedManifestObj, options: [.prettyPrinted, .sortedKeys])
      try tamperedManifestData.write(to: manifestURL)

      let checkPassed1 = try await CheckWorkflow.execute(json: false, prePush: false)
      #expect(!checkPassed1)

      _ = try await SubprocessRunner.run(
        binary: .git,
        arguments: ["-C", ctx.repoURL.path, "checkout", "--", "invariants/rules/no-print-in-sources"])

      // 2. Direct registry.lock tampering
      let lockURL = RegistryManager.registryURL()
      var reg2 = try await RegistryManager.loadAndVerify()
      reg2.rules.removeAll()
      let tamperedLockData = try #require(CanonicalJSON.serialize(reg2).data(using: .utf8))
      try tamperedLockData.write(to: lockURL)

      await #expect(throws: RegistryError.self) {
        _ = try await RegistryManager.loadAndVerify()
      }

      _ = try await SubprocessRunner.run(
        binary: .git,
        arguments: ["-C", ctx.repoURL.path, "checkout", "--", "invariants/registry.lock"])

      // 3. Rogue signer self-enrollment attack
      var reg3 = try await RegistryManager.loadAndVerify()
      let signersURL = RegistryManager.allowedSignersURL()
      let origSigners = try signersURL.readUTF8()
      let rogueSigners = origSigners + "* namespaces=\"invariants\" \(ctx.rogueAgentPub)\n"
      try rogueSigners.write(to: signersURL, atomically: true, encoding: .utf8)

      reg3.version = 3
      try await RegistryManager.saveAndSign(registry: reg3, keyURL: ctx.rogueAgentKey)
      try await GitClient.commit(paths: ["invariants"], message: "Agent unauthorized self-enrollment")

      await #expect(throws: FloorError.self) {
        try await FloorGuard.checkSignerAncestry(currentRegistry: reg3)
      }

      _ = try await SubprocessRunner.run(
        binary: .git, arguments: ["-C", ctx.repoURL.path, "reset", "--hard", "HEAD~1"])

      // 4. Pre-push hook blocks forbidden branch push
      let forcePushStdin = "refs/heads/feature 1111 refs/heads/main 2222\n"
      await #expect(throws: CheckWorkflowError.self) {
        _ = try await CheckWorkflow.execute(
          json: false, prePush: true, stdinInput: forcePushStdin)
      }
    }
  }

  /// Week 3: Bob joins; Alice enrolls Bob as the second active signer -> v3
  static func step_v03_week3_enrollBob(ctx: AcmeJourneyContext) async throws {
    try await ctx.run {
      try await SignersWorkflow.add(
        key: ctx.bobPub,
        identity: "bob@acme.com",
        signingKey: ctx.aliceKey.path
      )

      let reg = try await RegistryManager.loadAndVerify()
      #expect(reg.version == 3)

      let signers = try SignersManager.loadSigners()
      #expect(signers.count == 2)
      #expect(signers.contains(where: { $0.matches(keyString: ctx.bobPub) }))

      try await FloorGuard.checkSignerAncestry(currentRegistry: reg)
    }
  }
}

// MARK: - Phase 2: Month 2 to Month 3 (v4 to v8)

extension AcmeSteps {
  /// Month 2: Alice configures TypeScript language analysis alongside Swift -> v4
  static func step_v04_month2_configTypeScript(ctx: AcmeJourneyContext) async throws {
    try await ctx.run {
      let fm = FileManager.default
      let webDir = ctx.repoURL.appendingPathComponent("web")
      try fm.createDirectory(
        at: webDir.appendingPathComponent("src"), withIntermediateDirectories: true)

      let tsconfig = """
        {
          "compilerOptions": {
            "target": "ES2022",
            "module": "NodeNext"
          },
          "include": ["src/**/*"]
        }
        """
      try tsconfig.write(
        to: webDir.appendingPathComponent("tsconfig.json"), atomically: true, encoding: .utf8)
      try "export const apiHost = 'https://api.acme.com';\n".write(
        to: webDir.appendingPathComponent("src/index.ts"), atomically: true, encoding: .utf8)

      _ = try await SubprocessRunner.run(
        binary: .git, arguments: ["-C", ctx.repoURL.path, "add", "web"])
      _ = try await SubprocessRunner.run(
        binary: .git, arguments: ["-C", ctx.repoURL.path, "commit", "-m", "Add web application"])

      try await Terminal.withInteractiveSession {
        try await ConfigWorkflow.execute(
          languages: [.swift, .ts],
          defaultBranch: "main",
          keyPath: ctx.aliceKey.path
        )
      }

      let reg = try await RegistryManager.loadAndVerify()
      #expect(reg.version == 4)
      #expect(reg.languages[TypeScriptLanguage.self] != nil)
      try await FloorGuard.checkSignerAncestry(currentRegistry: reg)
    }
  }

  /// Month 2: Bob enrolls Carol (web lead) -> v5
  static func step_v05_month2_enrollCarol(ctx: AcmeJourneyContext) async throws {
    try await ctx.run {
      try await SignersWorkflow.add(
        key: ctx.carolPub,
        identity: "carol@acme.com",
        signingKey: ctx.bobKey.path
      )

      let reg = try await RegistryManager.loadAndVerify()
      #expect(reg.version == 5)

      let signers = try SignersManager.loadSigners()
      #expect(signers.count == 3)
      #expect(signers.contains(where: { $0.matches(keyString: ctx.carolPub) }))

      try await FloorGuard.checkSignerAncestry(currentRegistry: reg)
    }
  }

  /// Month 2: Carol creates, tests, and activates TypeScript rule 'isolate-ui-from-db' -> v6
  static func step_v06_month2_addTypeScriptRule(ctx: AcmeJourneyContext) async throws {
    try await ctx.run {
      try NewRuleWorkflow.execute(id: "isolate-ui-from-db", targets: [.ts])

      let ruleDir = ctx.repoURL.appendingPathComponent("invariants/rules/isolate-ui-from-db")
      let manifestURL = ruleDir.appendingPathComponent("manifest.json")
      let manifestObj: [String: Any] = [
        "id": "isolate-ui-from-db",
        "summary": "Forbid direct database imports in web UI components",
        "targets": ["ts"],
        "scope": ["ts": ["include": ["web/src/**/*.ts"]]],
        "codes": ["UI-DB-IMPORT": "Direct DB access is forbidden in UI components."],
      ]
      let manifestData = try JSONSerialization.data(
        withJSONObject: manifestObj, options: [.prettyPrinted, .sortedKeys])
      try manifestData.write(to: manifestURL)

      let ruleTs = """
        import * as fs from "node:fs";
        import * as path from "node:path";
        import { defineRule } from "@invariants/kit";

        export default defineRule({
          check(ctx) {
            const violations = [];
            for (const file of ctx.files) {
              const sf = ctx.sourceFile(file);
              let text = sf?.getFullText();
              if (!text) {
                const absPath = path.isAbsolute(file) ? file : path.resolve(ctx.repoRoot, file);
                if (fs.existsSync(absPath)) {
                  text = fs.readFileSync(absPath, "utf8");
                }
              }
              if (text && (text.includes("from './db'") || text.includes("from '../db'"))) {
                violations.push({
                  code: "UI-DB-IMPORT",
                  file,
                  line: 1,
                  column: 1,
                  message: "Direct DB access is forbidden in UI components.",
                  fix: "Use API client"
                });
              }
            }
            return violations;
          }
        });
        """
      try ruleTs.write(
        to: ruleDir.appendingPathComponent("rule.ts"), atomically: true, encoding: .utf8)

      let passFixture = ruleDir.appendingPathComponent("should_pass/ts/case1.ts")
      try "export const header = 'Acme Header';\n".write(
        to: passFixture, atomically: true, encoding: .utf8)

      let failFixture = ruleDir.appendingPathComponent("should_fail/ts/case1.ts")
      try "import { query } from './db'; // expect: UI-DB-IMPORT\n".write(
        to: failFixture, atomically: true, encoding: .utf8)

      try await Terminal.withInteractiveSession {
        try await AddRuleWorkflow.execute(ruleId: "isolate-ui-from-db", keyPath: ctx.carolKey.path)
      }

      let reg = try await RegistryManager.loadAndVerify()
      #expect(reg.version == 6)
      #expect(reg.rules["isolate-ui-from-db"] != nil)
      try await FloorGuard.checkSignerAncestry(currentRegistry: reg)
    }
  }

  /// Month 3: Carol enrolls Dave (contractor) -> v7
  static func step_v07_month3_enrollDave(ctx: AcmeJourneyContext) async throws {
    try await ctx.run {
      try await SignersWorkflow.add(
        key: ctx.davePub,
        identity: "dave-contractor",
        signingKey: ctx.carolKey.path
      )

      let reg = try await RegistryManager.loadAndVerify()
      #expect(reg.version == 7)

      let signers = try SignersManager.loadSigners()
      #expect(signers.count == 4)
      #expect(signers.contains(where: { $0.matches(keyString: ctx.davePub) }))

      try await FloorGuard.checkSignerAncestry(currentRegistry: reg)
    }
  }

  /// Month 3: Bob strengthens Swift rule with 'NO-DUMP' code and fixture -> v8
  static func step_v08_month3_strengthenSwiftRule(ctx: AcmeJourneyContext) async throws {
    try await ctx.run {
      let ruleDir = ctx.repoURL.appendingPathComponent("invariants/rules/no-print-in-sources")
      let manifestURL = ruleDir.appendingPathComponent("manifest.json")
      let manifestObj: [String: Any] = [
        "id": "no-print-in-sources",
        "summary": "Forbid print() and dump() calls in production sources",
        "targets": ["swift"],
        "scope": ["swift": ["include": ["Sources/**/*.swift"]]],
        "codes": [
          "NO-PRINT": "print() calls are forbidden in production code.",
          "NO-DUMP": "dump() calls are forbidden in production code.",
        ],
      ]
      let manifestData = try JSONSerialization.data(
        withJSONObject: manifestObj, options: [.prettyPrinted, .sortedKeys])
      try manifestData.write(to: manifestURL)

      let ruleSwift = """
        import InvariantKit

        @main
        struct NoPrintInSourcesRule: SwiftRule {
            func check(_ ctx: RuleContext) throws(RuleError) -> [Violation] {
                let sources = SourceFileCollection(files: ctx.files, repoRoot: ctx.repoRoot)
                var result = sources.calls(named: "print").violations(
                    code: "NO-PRINT",
                    message: { _ in "print() calls are forbidden in production code." },
                    fix: "Logger.info(...)"
                )
                result += sources.calls(named: "dump").violations(
                    code: "NO-DUMP",
                    message: { _ in "dump() calls are forbidden in production code." },
                    fix: "Logger.debug(...)"
                )
                return result
            }
        }
        """
      try ruleSwift.write(
        to: ruleDir.appendingPathComponent("rule.swift"), atomically: true, encoding: .utf8)

      let fail2Fixture = ruleDir.appendingPathComponent("should_fail/swift/case2.swift")
      try "func dumpState() { dump(self) } // expect: NO-DUMP\n".write(
        to: fail2Fixture, atomically: true, encoding: .utf8)

      try await UpdateRuleWorkflow.execute(
        input: .init(id: "no-print-in-sources", keyPath: ctx.bobKey.path)
      )

      let reg = try await RegistryManager.loadAndVerify()
      #expect(reg.version == 8)
      try await FloorGuard.checkSignerAncestry(currentRegistry: reg)
    }
  }

  /// Month 3: Dave attempts to weaken scope by excluding sources; blocked without typed confirm -> v8 unchanged
  static func step_interlude_month3_weakeningBlocked(ctx: AcmeJourneyContext) async throws {
    try await ctx.run {
      let ruleDir = ctx.repoURL.appendingPathComponent("invariants/rules/no-print-in-sources")
      let manifestURL = ruleDir.appendingPathComponent("manifest.json")
      let manifestObj: [String: Any] = [
        "id": "no-print-in-sources",
        "summary": "Forbid print() and dump() calls",
        "targets": ["swift"],
        "scope": ["swift": ["include": ["Sources/AcmeCore/App.swift"]]],
        "codes": [
          "NO-PRINT": "print() calls are forbidden in production code.",
          "NO-DUMP": "dump() calls are forbidden in production code.",
        ],
      ]
      let manifestData = try JSONSerialization.data(
        withJSONObject: manifestObj, options: [.prettyPrinted, .sortedKeys])
      try manifestData.write(to: manifestURL)

      await #expect(throws: UpdateRuleWorkflowError.self) {
        try await Terminal.withInteractiveSession(
          mode: .forceInteractive,
          readLineHandler: { "wrong-id" },
          operation: {
            try await UpdateRuleWorkflow.execute(
              input: .init(id: "no-print-in-sources", keyPath: ctx.daveKey.path)
            )
          }
        )
      }

      _ = try await SubprocessRunner.run(
        binary: .git,
        arguments: ["-C", ctx.repoURL.path, "checkout", "--", "invariants/rules/no-print-in-sources"])

      let reg = try await RegistryManager.loadAndVerify()
      #expect(reg.version == 8)
    }
  }
}

// MARK: - Phase 3: Month 4 to Month 12 (v9 to v13 + Mature Audit)

extension AcmeSteps {
  /// Month 4: Bob rotates key with a 1-hour sunset grace period on his old key -> v9
  static func step_v09_month4_rotateBobKeyWithSunset(ctx: AcmeJourneyContext) async throws {
    try await ctx.run {
      try await SignersWorkflow.rotate(
        old: ctx.bobPub,
        new: ctx.bobNewPub,
        sunset: 3600,
        signingKey: ctx.bobKey.path
      )

      let reg = try await RegistryManager.loadAndVerify()
      #expect(reg.version == 9)

      let signers = try SignersManager.loadSigners()
      #expect(signers.contains(where: { $0.matches(keyString: ctx.bobPub) && $0.validBefore != nil }))
      #expect(signers.contains(where: { $0.matches(keyString: ctx.bobNewPub) && $0.validAfter != nil }))

      try await FloorGuard.checkSignerAncestry(currentRegistry: reg)
    }
  }

  /// Month 4: Bob re-seals registry configuration using his new key on his replacement Mac -> v10
  static func step_v10_month4_reSealWithBobNewKey(ctx: AcmeJourneyContext) async throws {
    try await ctx.run {
      try await Terminal.withInteractiveSession {
        try await ConfigWorkflow.execute(
          languages: [.swift, .ts],
          defaultBranch: "main",
          keyPath: ctx.bobNewKey.path
        )
      }

      let reg = try await RegistryManager.loadAndVerify()
      #expect(reg.version == 10)
      try await FloorGuard.checkSignerAncestry(currentRegistry: reg)
    }
  }

  /// Month 6: Dave's contract ends; Carol soft-revokes Dave with valid-before -> v11
  static func step_v11_month6_revokeDaveSoft(ctx: AcmeJourneyContext) async throws {
    try await ctx.run {
      try await SignersWorkflow.revoke(
        pattern: ctx.davePub,
        hard: false,
        signingKey: ctx.carolKey.path
      )

      let reg = try await RegistryManager.loadAndVerify()
      #expect(reg.version == 11)

      let signers = try SignersManager.loadSigners()
      let daveEntry = try #require(signers.first(where: { $0.matches(keyString: ctx.davePub) }))
      #expect(daveEntry.validBefore != nil)

      // Dave cannot sign future mutations
      await #expect(throws: SigningError.self) {
        try await SignersWorkflow.add(
          key: ctx.rogueAgentPub,
          identity: nil,
          signingKey: ctx.daveKey.path
        )
      }

      // But all history signed during Dave's tenure still verifies cleanly!
      try await FloorGuard.checkSignerAncestry(currentRegistry: reg)
    }
  }

  /// Month 7: Bob's old laptop is stolen; Alice executes an emergency hard revocation of the old key -> v12
  static func step_v12_month7_incidentHardRevokeBobOld(ctx: AcmeJourneyContext) async throws {
    try await ctx.run {
      try await SignersWorkflow.revoke(
        pattern: ctx.bobPub,
        hard: true,
        signingKey: ctx.aliceKey.path
      )

      let reg = try await RegistryManager.loadAndVerify()
      #expect(reg.version == 12)

      let signers = try SignersManager.loadSigners()
      #expect(!signers.contains(where: { $0.matches(keyString: ctx.bobPub) }))
      #expect(signers.contains(where: { $0.matches(keyString: ctx.bobNewPub) }))

      try await FloorGuard.checkSignerAncestry(currentRegistry: reg)
    }
  }

  /// Month 8: Alice runs upgrade-registry to bump engine constraint and re-verify all active rules -> v13
  static func step_v13_month8_upgradeEngine(ctx: AcmeJourneyContext) async throws {
    try await ctx.run {
      try await Terminal.withInteractiveSession {
        try await UpgradeWorkflow.execute(keyPath: ctx.aliceKey.path)
      }

      let reg = try await RegistryManager.loadAndVerify()
      #expect(reg.version == 13)
      try await FloorGuard.checkSignerAncestry(currentRegistry: reg)
    }
  }

  /// Month 12: Final audit of the mature multi-signer, multi-language repository
  static func step_audit_month12_matureRepository(ctx: AcmeJourneyContext) async throws {
    try await ctx.run {
      // 1. History floor is at version 13
      let floor = try await FloorGuard.checkHistory(currentVersion: 13)
      #expect(floor == 13)

      // 2. Full 13-version ancestry graph verifies cleanly across all historical commit dates
      let reg = try await RegistryManager.loadAndVerify()
      #expect(reg.version == 13)
      try await FloorGuard.checkSignerAncestry(currentRegistry: reg)

      // 3. Inspect active vs discontinued signers
      let signers = try SignersManager.loadSigners()
      let now = Date()
      let active = signers.filter { $0.isActive(at: now) }
      let inactive = signers.filter { !$0.isActive(at: now) }

      #expect(active.contains(where: { $0.matches(keyString: ctx.alicePub) }))
      #expect(active.contains(where: { $0.matches(keyString: ctx.bobNewPub) }))
      #expect(active.contains(where: { $0.matches(keyString: ctx.carolPub) }))
      #expect(inactive.contains(where: { $0.matches(keyString: ctx.davePub) }))
      #expect(!signers.contains(where: { $0.matches(keyString: ctx.bobPub) }))

      // 4. Clean codebase enforcement
      let cleanPassed = try await CheckWorkflow.execute(json: false, prePush: false)
      #expect(cleanPassed)

      // 5. Swift rule enforcement in production code
      let badSwift = ctx.repoURL.appendingPathComponent("Sources/AcmeCore/BadLogging.swift")
      try "func leak() { print(\"debug leak\") }\n".write(
        to: badSwift, atomically: true, encoding: .utf8)

      let swiftPassed = try await CheckWorkflow.execute(json: false, prePush: false)
      #expect(!swiftPassed)
      try FileManager.default.removeItem(at: badSwift)

      // 6. TypeScript rule enforcement in web components
      let badTS = ctx.repoURL.appendingPathComponent("web/src/BadComponent.ts")
      try "import { query } from './db';\nexport const x = 1;\n".write(
        to: badTS, atomically: true, encoding: .utf8)

      let tsPassed = try await CheckWorkflow.execute(json: false, prePush: false)
      #expect(!tsPassed)
      try FileManager.default.removeItem(at: badTS)

      // Clean restoration check
      let finalPassed = try await CheckWorkflow.execute(json: false, prePush: false)
      #expect(finalPassed)
    }
  }
}
