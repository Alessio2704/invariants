import Foundation
import Testing

@testable import Core
@testable import InvariantKit
@testable import Managers
@testable import Workflows

@Suite("Multi-Unit Rule Enforcement End-to-End Simulation Tests", .tags(.scenario))
struct MultiUnitRuleEnforcementE2ETests {
  @Test("E2E Scenario: Swift monorepo cross-unit contract rule across 'ios' and 'vapor' AST units")
  func e2eSwiftMonorepoCrossUnitContractRule() async throws {
    let repo = try await TestRepo()

    var ast = ASTConfig()
    ast[SwiftLanguage.self] = [
      "ios": SwiftLanguage.Config(indexStore: "build/ios/Index.noindex/DataStore"),
      "vapor": SwiftLanguage.Config(indexStore: "build/vapor/Index.noindex/DataStore"),
    ]

    let ruleSwift = """
      import InvariantKit

      @main
      struct CrossUnitContractRule: SwiftRule {
          func check(_ ctx: RuleContext) throws(RuleError) -> [Violation] {
              guard let iosUnit = ctx.ast["ios"] else { return [] }
              var violations: [Violation] = []
              for file in iosUnit.files {
                  if let sf = iosUnit.sourceFile(file), sf.sourceText.contains("MismatchedDTO") {
                      violations.append(Violation(
                          code: "CONTRACT-01",
                          file: file.path,
                          line: 1,
                          column: 1,
                          message: "DTO mismatch across units",
                          fix: "Align DTO models"
                      ))
                  }
              }
              return violations
          }
      }
      """

    let ruleDir = repo.repoURL.appendingPathComponent("invariants/rules/cross-unit-contract")
    let fm = FileManager.default

    // Multi-unit folder fixtures
    let passFolder = ruleDir.appendingPathComponent("should_pass/swift/valid_contract")
    let passIos = passFolder.appendingPathComponent("ios")
    let passVapor = passFolder.appendingPathComponent("vapor")
    try fm.createDirectory(at: passIos, withIntermediateDirectories: true)
    try fm.createDirectory(at: passVapor, withIntermediateDirectories: true)
    try "struct ValidUser: Codable {}\n".write(
      to: passIos.appendingPathComponent("AppDTO.swift"), atomically: true, encoding: .utf8)
    try "struct ValidUser: Codable {}\n".write(
      to: passVapor.appendingPathComponent("ServerDTO.swift"), atomically: true, encoding: .utf8)

    let failFolder = ruleDir.appendingPathComponent("should_fail/swift/mismatched_contract")
    let failIos = failFolder.appendingPathComponent("ios")
    let failVapor = failFolder.appendingPathComponent("vapor")
    try fm.createDirectory(at: failIos, withIntermediateDirectories: true)
    try fm.createDirectory(at: failVapor, withIntermediateDirectories: true)
    try "struct MismatchedDTO: Codable {} // expect: CONTRACT-01\n".write(
      to: failIos.appendingPathComponent("AppDTO.swift"), atomically: true, encoding: .utf8)
    try "struct ValidUser: Codable {}\n".write(
      to: failVapor.appendingPathComponent("ServerDTO.swift"), atomically: true, encoding: .utf8)

    let manifestObj: [String: Any] = [
      "id": "cross-unit-contract",
      "summary": "Enforce cross-unit contract between iOS and Vapor",
      "targets": ["swift"],
      "scope": [
        "swift": [
          "ios": ["include": ["apps/ios/**/*.swift"]],
          "vapor": ["include": ["services/vapor/**/*.swift"]],
        ]
      ],
      "codes": ["CONTRACT-01": "DTO mismatch across units"],
    ]
    let manifestData = try JSONSerialization.data(withJSONObject: manifestObj, options: [.prettyPrinted, .sortedKeys])
    try manifestData.write(to: ruleDir.appendingPathComponent("manifest.json"))
    try ruleSwift.write(to: ruleDir.appendingPathComponent("rule.swift"), atomically: true, encoding: .utf8)

    // Repo production files
    let appFile = repo.repoURL.appendingPathComponent("apps/ios/AppDTO.swift")
    let serverFile = repo.repoURL.appendingPathComponent("services/vapor/ServerDTO.swift")
    try fm.createDirectory(at: appFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createDirectory(at: serverFile.deletingLastPathComponent(), withIntermediateDirectories: true)

    try "struct ValidUser: Codable {}\n".write(to: appFile, atomically: true, encoding: .utf8)
    try "struct ValidUser: Codable {}\n".write(to: serverFile, atomically: true, encoding: .utf8)

    let manifest = try ManifestParser.parse(data: manifestData)
    let ruleTreeHash = "multi_unit_hash"

    // Execute runner directly with multi-unit request
    let runner = RuleRunner()
    let passReq = RuleRequest(
      mode: "repo",
      repoRoot: repo.repoURL.path,
      ruleDir: ruleDir.path,
      files: [appFile.path, serverFile.path],
      unitFiles: [
        "ios": [appFile.path],
        "vapor": [serverFile.path],
      ],
      ast: ast
    )
    let initialViolations = try await runner.execute(
      target: .swift,
      ruleDirectory: ruleDir,
      ruleTreeHash: ruleTreeHash,
      request: passReq
    )
    #expect(initialViolations.isEmpty)

    // Introduce violating mismatch in apps/ios
    try "struct MismatchedDTO: Codable {}\n".write(to: appFile, atomically: true, encoding: .utf8)
    let failReq = RuleRequest(
      mode: "repo",
      repoRoot: repo.repoURL.path,
      ruleDir: ruleDir.path,
      files: [appFile.path, serverFile.path],
      unitFiles: [
        "ios": [appFile.path],
        "vapor": [serverFile.path],
      ],
      ast: ast
    )
    let violations = try await runner.execute(
      target: .swift,
      ruleDirectory: ruleDir,
      ruleTreeHash: ruleTreeHash,
      request: failReq
    )
    #expect(violations.count == 1)
    let first = violations[0]
    #expect(first.code == "CONTRACT-01")
    #expect(first.file.hasSuffix("AppDTO.swift"))

    // Verify fixtures pass via FixtureExecutionService with multi-unit folder fixtures
    try await FixtureExecutionService.verifyAllFixtures(
      manifest: manifest,
      ruleDirectory: ruleDir,
      ruleTreeHash: ruleTreeHash,
      ast: ast,
      runner: runner
    )
  }

  @Test("E2E Scenario: Full-stack TypeScript monorepo with isolated AST units and checkers ('web' and 'bff')")
  func e2eTypeScriptMonorepoIsolatedCheckers() async throws {
    let repo = try await TestRepo()

    let tsRule = """
      import { defineRule } from "@invariants/kit";

      export default defineRule({
        check(ctx) {
          const webUnit = ctx.ast["web"];
          if (!webUnit) return [];
          const violations = [];
          for (const file of webUnit.files) {
            const sf = webUnit.sourceFile(file);
            if (sf && sf.getText().includes("SECRET_KEY")) {
              violations.push({
                code: "TS-LEAK-01",
                file,
                line: 1,
                column: 1,
                message: "SECRET_KEY leaked to web client AST unit",
                fix: "Move secret to BFF unit",
              });
            }
          }
          return violations;
        },
      });
      """

    let ruleDir = repo.repoURL.appendingPathComponent("invariants/rules/no-secret-in-web")
    let fm = FileManager.default

    // Multi-unit folder fixtures for TS
    let passFolder = ruleDir.appendingPathComponent("should_pass/ts/clean")
    let passWeb = passFolder.appendingPathComponent("web")
    let passBff = passFolder.appendingPathComponent("bff")
    try fm.createDirectory(at: passWeb, withIntermediateDirectories: true)
    try fm.createDirectory(at: passBff, withIntermediateDirectories: true)
    try "export const title = 'clean';\n".write(
      to: passWeb.appendingPathComponent("client.ts"), atomically: true, encoding: .utf8)
    try "export const SECRET_KEY = 'secret';\n".write(
      to: passBff.appendingPathComponent("server.ts"), atomically: true, encoding: .utf8)

    let failFolder = ruleDir.appendingPathComponent("should_fail/ts/leak")
    let failWeb = failFolder.appendingPathComponent("web")
    let failBff = failFolder.appendingPathComponent("bff")
    try fm.createDirectory(at: failWeb, withIntermediateDirectories: true)
    try fm.createDirectory(at: failBff, withIntermediateDirectories: true)
    try "export const leak = SECRET_KEY; // expect: TS-LEAK-01\n".write(
      to: failWeb.appendingPathComponent("client.ts"), atomically: true, encoding: .utf8)
    try "export const SECRET_KEY = 'secret';\n".write(
      to: passBff.appendingPathComponent("server.ts"), atomically: true, encoding: .utf8)

    let manifestObj: [String: Any] = [
      "id": "no-secret-in-web",
      "summary": "Forbid secrets in web AST unit",
      "targets": ["ts"],
      "scope": [
        "ts": [
          "web": ["include": ["apps/web/**/*.ts"]],
          "bff": ["include": ["apps/bff/**/*.ts"]],
        ]
      ],
      "codes": ["TS-LEAK-01": "Secret leaked to web unit"],
    ]
    let manifestData = try JSONSerialization.data(withJSONObject: manifestObj, options: [.prettyPrinted, .sortedKeys])
    try manifestData.write(to: ruleDir.appendingPathComponent("manifest.json"))
    try tsRule.write(to: ruleDir.appendingPathComponent("rule.ts"), atomically: true, encoding: .utf8)

    // Setup production monorepo tsconfigs and source files
    let webTsconfig = repo.repoURL.appendingPathComponent("apps/web/tsconfig.json")
    let bffTsconfig = repo.repoURL.appendingPathComponent("apps/bff/tsconfig.json")
    try fm.createDirectory(at: webTsconfig.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createDirectory(at: bffTsconfig.deletingLastPathComponent(), withIntermediateDirectories: true)
    try """
    {
      "compilerOptions": { "target": "ES2022", "module": "NodeNext" },
      "include": ["src/**/*"]
    }
    """.write(to: webTsconfig, atomically: true, encoding: .utf8)
    try """
    {
      "compilerOptions": { "target": "ES2022", "module": "NodeNext" },
      "include": ["src/**/*"]
    }
    """.write(to: bffTsconfig, atomically: true, encoding: .utf8)

    var ast = ASTConfig()
    ast[TypeScriptLanguage.self] = [
      "web": TypeScriptLanguage.Config(tsconfig: "apps/web/tsconfig.json"),
      "bff": TypeScriptLanguage.Config(tsconfig: "apps/bff/tsconfig.json"),
    ]

    let webFile = repo.repoURL.appendingPathComponent("apps/web/src/client.ts")
    let bffFile = repo.repoURL.appendingPathComponent("apps/bff/src/server.ts")
    try fm.createDirectory(at: webFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createDirectory(at: bffFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "export const safe = true;\n".write(to: webFile, atomically: true, encoding: .utf8)
    try "export const SECRET_KEY = 'secret_env';\n".write(to: bffFile, atomically: true, encoding: .utf8)

    let manifest = try ManifestParser.parse(data: manifestData)
    let ruleTreeHash = "multi_unit_ts_hash"
    let runner = RuleRunner()

    // 1. Fixture self-test with isolated AST units and checkers
    try await FixtureExecutionService.verifyAllFixtures(
      manifest: manifest,
      ruleDirectory: ruleDir,
      ruleTreeHash: ruleTreeHash,
      ast: ast,
      runner: runner
    )

    // 2. Clean repo run: secret in BFF is allowed, clean in web
    let cleanReq = RuleRequest(
      mode: "repo",
      repoRoot: repo.repoURL.path,
      ruleDir: ruleDir.path,
      files: [webFile.path, bffFile.path],
      unitFiles: [
        "web": [webFile.path],
        "bff": [bffFile.path],
      ],
      ast: ast
    )
    let cleanViolations = try await runner.execute(
      target: .ts,
      ruleDirectory: ruleDir,
      ruleTreeHash: ruleTreeHash,
      request: cleanReq
    )
    #expect(cleanViolations.isEmpty)

    // 3. Violating file in apps/web
    try "export const key = SECRET_KEY;\n".write(to: webFile, atomically: true, encoding: .utf8)
    let failReq = RuleRequest(
      mode: "repo",
      repoRoot: repo.repoURL.path,
      ruleDir: ruleDir.path,
      files: [webFile.path, bffFile.path],
      unitFiles: [
        "web": [webFile.path],
        "bff": [bffFile.path],
      ],
      ast: ast
    )
    let failViolations = try await runner.execute(
      target: .ts,
      ruleDirectory: ruleDir,
      ruleTreeHash: ruleTreeHash,
      request: failReq
    )
    #expect(failViolations.count == 1)
    let v = failViolations[0]
    #expect(v.code == "TS-LEAK-01")
    #expect(v.file.hasSuffix("client.ts"))
  }
}

extension MultiUnitRuleEnforcementE2ETests {
  @Test("E2E Scenario: Blinding and weakening protection blocks removing unit scope")
  func e2eBlindingAndWeakeningProtectionMultiUnit() async throws {
    let repo = try await TestRepo()

    var ast = ASTConfig()
    ast[SwiftLanguage.self] = [
      "ios": SwiftLanguage.Config(indexStore: "build/ios/Index.noindex/DataStore"),
      "vapor": SwiftLanguage.Config(indexStore: "build/vapor/Index.noindex/DataStore"),
    ]

    let ruleSwift = """
      import InvariantKit

      @main
      struct MonorepoGuardRule: SwiftRule {
          func check(_ ctx: RuleContext) throws(RuleError) -> [Violation] {
              var violations: [Violation] = []
              for (unitName, unit) in ctx.ast {
                  for file in unit.files {
                      if let sf = unit.sourceFile(file), sf.sourceText.contains("forbidden") {
                          violations.append(Violation(
                              code: "FORBIDDEN-01",
                              file: file.path,
                              line: 1,
                              column: 1,
                              message: "forbidden() is disallowed",
                              fix: "remove"
                          ))
                      }
                  }
              }
              return violations
          }
      }
      """

    let ruleDir = repo.repoURL.appendingPathComponent("invariants/rules/monorepo-guard")
    let passFolder = ruleDir.appendingPathComponent("should_pass/swift/clean/ios")
    let failFolder = ruleDir.appendingPathComponent("should_fail/swift/forbidden/ios")
    let fm = FileManager.default
    try fm.createDirectory(at: passFolder, withIntermediateDirectories: true)
    try fm.createDirectory(at: failFolder, withIntermediateDirectories: true)
    try "// pass\n".write(to: passFolder.appendingPathComponent("case1.swift"), atomically: true, encoding: .utf8)
    try "// fail forbidden // expect: FORBIDDEN-01\n".write(
      to: failFolder.appendingPathComponent("case1.swift"), atomically: true, encoding: .utf8)

    // Initial manifest covering both ios and vapor units
    let origManifestObj: [String: Any] = [
      "id": "monorepo-guard",
      "summary": "Guard monorepo",
      "targets": ["swift"],
      "scope": [
        "swift": [
          "ios": ["include": ["apps/ios/**/*.swift"]],
          "vapor": ["include": ["services/vapor/**/*.swift"]],
        ]
      ],
      "codes": ["FORBIDDEN-01": "forbidden() is disallowed"],
    ]
    let origManifestData = try JSONSerialization.data(
      withJSONObject: origManifestObj, options: [.prettyPrinted, .sortedKeys])
    try origManifestData.write(to: ruleDir.appendingPathComponent("manifest.json"))
    try ruleSwift.write(to: ruleDir.appendingPathComponent("rule.swift"), atomically: true, encoding: .utf8)

    // Repo production files
    let iosFile = repo.repoURL.appendingPathComponent("apps/ios/App.swift")
    let vaporFile = repo.repoURL.appendingPathComponent("services/vapor/Service.swift")
    try fm.createDirectory(at: iosFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createDirectory(at: vaporFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "struct App {}\n".write(to: iosFile, atomically: true, encoding: .utf8)
    try "struct Service { let f = forbidden }\n".write(to: vaporFile, atomically: true, encoding: .utf8)

    // Lock initial rule into registry v1 using repo.signed
    try await repo.signed(
      version: 1,
      languages: [.swift],
      ast: ast
    )

    // Tampered manifest: vapor unit scope is DROPPED to blind the rule to vapor/Service.swift
    let tamperedManifestObj: [String: Any] = [
      "id": "monorepo-guard",
      "summary": "Guard monorepo",
      "targets": ["swift"],
      "scope": [
        "swift": [
          "ios": ["include": ["apps/ios/**/*.swift"]]
        ]
      ],
      "codes": ["FORBIDDEN-01": "forbidden() is disallowed"],
    ]
    let tamperedManifestData = try JSONSerialization.data(
      withJSONObject: tamperedManifestObj, options: [.prettyPrinted, .sortedKeys])
    try tamperedManifestData.write(to: ruleDir.appendingPathComponent("manifest.json"))

    // Weakening detector confirms .red unit scope removal
    let oldManifest = try ManifestParser.parse(data: origManifestData)
    let newManifest = try ManifestParser.parse(data: tamperedManifestData)
    let report = WeakeningDetector.detect(
      ruleId: "monorepo-guard",
      oldManifest: oldManifest,
      newManifest: newManifest,
      oldCases: [],
      newCases: []
    )
    #expect(
      report.items.contains(where: {
        $0.severity == .red && $0.message.contains("[swift.vapor] unit scope was removed")
      }))

    // UpdateRuleWorkflow fails fast because of red weakening and unconfirmed update
    await #expect(throws: (any Error).self) {
      try await repo.run {
        try await UpdateRuleWorkflow.execute(
          input: .init(id: "monorepo-guard", keyPath: repo.keyURL.path)
        )
      }
    }

    // Registry remains at version 1
    let regAfter = try await repo.run {
      try await RegistryManager.loadAndVerify()
    }
    #expect(regAfter.version == 1)
  }
}
