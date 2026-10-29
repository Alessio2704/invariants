import Foundation
import Testing

@testable import Core
@testable import InvariantKit
@testable import Managers
@testable import Workflows

@Suite("Polyglot 2x2 Monorepo E2E Simulation Tests", .tags(.scenario))
struct PolyglotTwoByTwoE2ETests {
  @Test("E2E Scenario: Polyglot 2x2 monorepo (Swift: ios + vapor, TS: web + bff) running full check workflow")
  func e2ePolyglotTwoByTwoMonorepo() async throws {
    let repo = try await TestRepo()

    var ast = ASTConfig()
    ast[SwiftLanguage.self] = [
      "ios": SwiftLanguage.Config(indexStore: "build/ios/Index.noindex/DataStore"),
      "vapor": SwiftLanguage.Config(indexStore: "build/vapor/Index.noindex/DataStore"),
    ]
    ast[TypeScriptLanguage.self] = [
      "web": TypeScriptLanguage.Config(tsconfig: "apps/web/tsconfig.json"),
      "bff": TypeScriptLanguage.Config(tsconfig: "apps/bff/tsconfig.json"),
    ]

    try setupRules(in: repo)
    let (vaporFile, bffFile) = try setupProductionFiles(in: repo)

    try await repo.signed(version: 1, languages: [.swift, .ts], ast: ast)

    // Run full repo check: clean -> true
    let cleanPassed = try await repo.run {
      try await CheckWorkflow.execute(json: false, prePush: false)
    }
    #expect(cleanPassed)

    // Introduce leak in services/vapor
    try "struct Server { let leak = 1 }\n".write(to: vaporFile, atomically: true, encoding: .utf8)
    let vaporLeakPassed = try await repo.run {
      try await CheckWorkflow.execute(json: false, prePush: false)
    }
    #expect(!vaporLeakPassed)

    // Resolve vapor leak, introduce leak in apps/bff
    try "struct Server {}\n".write(to: vaporFile, atomically: true, encoding: .utf8)
    try "export const bff = 'leak';\n".write(to: bffFile, atomically: true, encoding: .utf8)
    let bffLeakPassed = try await repo.run {
      try await CheckWorkflow.execute(json: false, prePush: false)
    }
    #expect(!bffLeakPassed)

    // Resolve bff leak -> clean
    try "export const bff = 1;\n".write(to: bffFile, atomically: true, encoding: .utf8)
    let finalPassed = try await repo.run {
      try await CheckWorkflow.execute(json: false, prePush: false)
    }
    #expect(finalPassed)
  }

  private func setupRules(in repo: TestRepo) throws {
    let fm = FileManager.default

    let swiftRuleCode = """
      import InvariantKit

      @main
      struct SwiftLeakRule: SwiftRule {
          func check(_ ctx: RuleContext) throws(RuleError) -> [Violation] {
              var violations: [Violation] = []
              for (_, unit) in ctx.ast {
                  for file in unit.files {
                      if let sf = unit.sourceFile(file), sf.sourceText.contains("leak") {
                          violations.append(Violation(
                              code: "SWIFT-01",
                              file: file.path,
                              line: 1,
                              column: 1,
                              message: "leak",
                              fix: "fix"
                          ))
                      }
                  }
              }
              return violations
          }
      }
      """

    let tsRuleCode = """
      import { defineRule } from "@invariants/kit";
      import * as fs from "fs";

      export default defineRule({
        check(ctx) {
          const violations = [];
          for (const [_, unit] of Object.entries(ctx.ast)) {
            for (const file of unit.files) {
              const sf = unit.sourceFile(file);
              const text = sf ? (sf.text ?? sf.getFullText()) : (fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "");
              if (text.includes("leak")) {
                violations.push({
                  code: "TS-01",
                  file,
                  line: 1,
                  column: 1,
                  message: "leak",
                  fix: "fix",
                });
              }
            }
          }
          return violations;
        },
      });
      """

    // Swift Rule
    let swiftRuleDir = repo.repoURL.appendingPathComponent("invariants/rules/swift-check")
    let swiftPassDir = swiftRuleDir.appendingPathComponent("should_pass/swift/case1/ios")
    let swiftFailDir = swiftRuleDir.appendingPathComponent("should_fail/swift/case1/ios")
    try fm.createDirectory(at: swiftPassDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: swiftFailDir, withIntermediateDirectories: true)
    try "// pass\n".write(to: swiftPassDir.appendingPathComponent("case1.swift"), atomically: true, encoding: .utf8)
    try "// fail leak // expect: SWIFT-01\n".write(
      to: swiftFailDir.appendingPathComponent("case1.swift"), atomically: true, encoding: .utf8)

    let swiftManifest: [String: Any] = [
      "id": "swift-check",
      "summary": "Check Swift monorepo",
      "targets": ["swift"],
      "scope": [
        "swift": [
          "ios": ["include": ["apps/ios/**/*.swift"]],
          "vapor": ["include": ["services/vapor/**/*.swift"]],
        ]
      ],
      "codes": ["SWIFT-01": "leak"],
    ]
    let swiftManifestData = try JSONSerialization.data(
      withJSONObject: swiftManifest, options: [.prettyPrinted, .sortedKeys])
    try swiftManifestData.write(to: swiftRuleDir.appendingPathComponent("manifest.json"))
    try swiftRuleCode.write(to: swiftRuleDir.appendingPathComponent("rule.swift"), atomically: true, encoding: .utf8)

    // TS Rule
    let tsRuleDir = repo.repoURL.appendingPathComponent("invariants/rules/ts-check")
    let tsPassDir = tsRuleDir.appendingPathComponent("should_pass/ts/case1/web")
    let tsFailDir = tsRuleDir.appendingPathComponent("should_fail/ts/case1/web")
    try fm.createDirectory(at: tsPassDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: tsFailDir, withIntermediateDirectories: true)
    try "export const safe = 1;\n".write(
      to: tsPassDir.appendingPathComponent("case1.ts"), atomically: true, encoding: .utf8)
    try "export const leak = 1; // expect: TS-01\n".write(
      to: tsFailDir.appendingPathComponent("case1.ts"), atomically: true, encoding: .utf8)

    let tsManifest: [String: Any] = [
      "id": "ts-check",
      "summary": "Check TS monorepo",
      "targets": ["ts"],
      "scope": [
        "ts": [
          "web": ["include": ["apps/web/**/*.ts"]],
          "bff": ["include": ["apps/bff/**/*.ts"]],
        ]
      ],
      "codes": ["TS-01": "leak"],
    ]
    let tsManifestData = try JSONSerialization.data(withJSONObject: tsManifest, options: [.prettyPrinted, .sortedKeys])
    try tsManifestData.write(to: tsRuleDir.appendingPathComponent("manifest.json"))
    try tsRuleCode.write(to: tsRuleDir.appendingPathComponent("rule.ts"), atomically: true, encoding: .utf8)
  }

  private func setupProductionFiles(in repo: TestRepo) throws -> (vapor: URL, bff: URL) {
    let fm = FileManager.default

    let iosFile = repo.repoURL.appendingPathComponent("apps/ios/App.swift")
    let vaporFile = repo.repoURL.appendingPathComponent("services/vapor/Server.swift")
    let webFile = repo.repoURL.appendingPathComponent("apps/web/src/app.ts")
    let bffFile = repo.repoURL.appendingPathComponent("apps/bff/src/server.ts")
    try fm.createDirectory(at: iosFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createDirectory(at: vaporFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createDirectory(at: webFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createDirectory(at: bffFile.deletingLastPathComponent(), withIntermediateDirectories: true)

    try "struct App {}\n".write(to: iosFile, atomically: true, encoding: .utf8)
    try "struct Server {}\n".write(to: vaporFile, atomically: true, encoding: .utf8)
    try "export const web = 1;\n".write(to: webFile, atomically: true, encoding: .utf8)
    try "export const bff = 1;\n".write(to: bffFile, atomically: true, encoding: .utf8)

    // TS configs
    try """
    {
      "compilerOptions": { "target": "ES2022", "module": "NodeNext" },
      "include": ["src/**/*"]
    }
    """.write(
      to: repo.repoURL.appendingPathComponent("apps/web/tsconfig.json"), atomically: true, encoding: .utf8)
    try """
    {
      "compilerOptions": { "target": "ES2022", "module": "NodeNext" },
      "include": ["src/**/*"]
    }
    """.write(
      to: repo.repoURL.appendingPathComponent("apps/bff/tsconfig.json"), atomically: true, encoding: .utf8)

    return (vaporFile, bffFile)
  }
}
