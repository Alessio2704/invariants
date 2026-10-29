import Foundation
import Testing

@testable import Core
@testable import InvariantKit

@Suite("End-to-End Rule Execution Integration Tests", .tags(.integration), .tags(.scenario))
struct IntegrationTests {
  @Test("End-to-end Swift rule execution: builds, executes, and catches violations via Fluent AST")
  func swiftRuleExecution() async throws {
    let repo = try await TestRepo()

    let ruleSwift = """
      let sources = SourceFileCollection(files: ctx.files, repoRoot: ctx.repoRoot)
      return sources.calls(named: "print").violations(
          code: "TEST-01",
          message: { _ in "print() calls are forbidden in production code." },
          fix: "Logger.info(...)"
      )
      """

    try repo.withRule(
      "forbid-print",
      targets: [.swift],
      ruleSwiftBody: ruleSwift,
      extraFiles: [
        "App/CleanService.swift": """
        struct CleanService {
            let value = 42
        }
        """,
        "App/ViolatingService.swift": """
        func doWork() {
            print("debug message")
        }
        """,
      ]
    )

    let ruleDir = repo.repoURL.appendingPathComponent("invariants/rules/forbid-print")
    let runner = RuleRunner()

    // 1. Execute on clean file -> 0 violations
    let cleanReq = RuleRequest(
      mode: "repo",
      repoRoot: repo.repoURL.path,
      ruleDir: ruleDir.path,
      files: ["App/CleanService.swift"],
      unitFiles: ["main": ["App/CleanService.swift"]],
      ast: TestRepo.defaultAST
    )
    let cleanViolations = try await runner.execute(
      target: .swift,
      ruleDirectory: ruleDir,
      ruleTreeHash: "integration_test_hash",
      request: cleanReq
    )
    #expect(cleanViolations.isEmpty)

    // 2. Execute on violating file -> catches violation with accurate line & code
    let violatingReq = RuleRequest(
      mode: "repo",
      repoRoot: repo.repoURL.path,
      ruleDir: ruleDir.path,
      files: ["App/ViolatingService.swift"],
      unitFiles: ["main": ["App/ViolatingService.swift"]],
      ast: TestRepo.defaultAST
    )
    let violations = try await runner.execute(
      target: .swift,
      ruleDirectory: ruleDir,
      ruleTreeHash: "integration_test_hash",
      request: violatingReq
    )
    #expect(violations.count == 1)
    let first = try #require(violations.first)
    #expect(first.code == "TEST-01")
    #expect(first.file.hasSuffix("ViolatingService.swift"))
    #expect(first.line == 2)
    #expect(first.message.contains("print() calls are forbidden"))
    #expect(first.fix == "Logger.info(...)")
  }

  @Test("End-to-end TypeScript rule execution: executes via Node runner and reports violations")
  func tsRuleExecution() async throws {
    let repo = try await TestRepo()

    let ruleTs = """
      const violations = [];
      for (const filePath of ctx.files) {
        const sf = ctx.sourceFile(filePath);
        const text = sf?.getFullText() ?? "";
        if (text.includes("console.log")) {
          violations.push({
            code: "TEST-01",
            file: filePath,
            line: 1,
            column: 1,
            message: "console.log statements are forbidden.",
            fix: "Use AppLogger"
          });
        }
      }
      return violations;
      """

    try repo.withRule(
      "forbid-console",
      targets: [.ts],
      ruleTsBody: ruleTs,
      extraFiles: [
        "tsconfig.json":
          "{\n  \"compilerOptions\": { \"target\": \"ES2022\", \"module\": \"NodeNext\" },\n  \"include\": [\"src/**/*.ts\"]\n}\n",
        "src/CleanModule.ts": "export const config = { port: 8080 };\n",
        "src/ViolatingModule.ts": "console.log('unauthorized leak');\n",
      ]
    )

    let ruleDir = repo.repoURL.appendingPathComponent("invariants/rules/forbid-console")
    let runner = RuleRunner()

    var tsAST = ASTConfig()
    tsAST[TypeScriptLanguage.self] = ["main": TypeScriptLanguage.Config(tsconfig: "tsconfig.json")]

    // 1. Execute on clean file -> 0 violations
    let cleanReq = RuleRequest(
      mode: "repo",
      repoRoot: repo.repoURL.path,
      ruleDir: ruleDir.path,
      files: ["src/CleanModule.ts"],
      unitFiles: ["main": ["src/CleanModule.ts"]],
      ast: tsAST
    )
    let cleanViolations = try await runner.execute(
      target: .ts,
      ruleDirectory: ruleDir,
      ruleTreeHash: "ts_integration_hash",
      request: cleanReq
    )
    #expect(cleanViolations.isEmpty)

    // 2. Execute on violating file -> catches violation
    let violatingReq = RuleRequest(
      mode: "repo",
      repoRoot: repo.repoURL.path,
      ruleDir: ruleDir.path,
      files: ["src/ViolatingModule.ts"],
      unitFiles: ["main": ["src/ViolatingModule.ts"]],
      ast: tsAST
    )
    let violations = try await runner.execute(
      target: .ts,
      ruleDirectory: ruleDir,
      ruleTreeHash: "ts_integration_hash",
      request: violatingReq
    )
    #expect(violations.count == 1)
    let first = try #require(violations.first)
    #expect(first.code == "TEST-01")
    #expect(first.file.hasSuffix("ViolatingModule.ts"))
    #expect(first.line == 1)
    #expect(first.message.contains("console.log statements are forbidden"))
  }
}
