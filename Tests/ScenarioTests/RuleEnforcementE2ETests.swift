import Foundation
import Testing

@testable import Core
@testable import InvariantKit
@testable import Managers
@testable import Workflows

@Suite("Rule Enforcement End-to-End Simulation Tests", .tags(.integration), .tags(.scenario))
struct RuleEnforcementE2ETests {
  @Test("E2E Simulation: Creates repo, defines Swift rule with fixtures, enforces against clean and violating files")
  func e2eSwiftRuleLifecycle() async throws {
    let repo = try await TestRepo()

    var ast = ASTConfig()
    ast[SwiftLanguage.self] = ["main": SwiftLanguage.Config(indexStore: "build/Index.noindex/DataStore")]

    let ruleSwiftBody = """
      let sources = SourceFileCollection(files: ctx.files, repoRoot: ctx.repoRoot)
      return sources.calls(named: "fatalError").violations(
          code: "NO-FATAL-ERROR",
          message: { _ in "fatalError() calls are strictly prohibited in production code." },
          fix: "throw AppError.unrecoverable"
      )
      """

    try repo.withRule(
      "no-fatal-error",
      targets: [.swift],
      ruleSwiftBody: ruleSwiftBody,
      extraFiles: [
        "App/SafeService.swift": "struct SafeService { func process() -> Int { 42 } }\n"
      ]
    )

    let failFixtureURL = repo.repoURL.appendingPathComponent(
      "invariants/rules/no-fatal-error/should_fail/swift/case1.swift")
    try Data("func crash() { fatalError(\"unhandled state\") } // expect: NO-FATAL-ERROR\n".utf8).write(
      to: failFixtureURL)

    let manifestURL = repo.repoURL.appendingPathComponent("invariants/rules/no-fatal-error/manifest.json")
    let manifestObj: [String: Any] = [
      "id": "no-fatal-error",
      "summary": "Forbid fatalError calls",
      "targets": ["swift"],
      "scope": ["swift": ["main": ["include": ["App/**/*.swift"]]]],
      "codes": ["NO-FATAL-ERROR": "fatalError() calls are strictly prohibited"],
    ]
    let manifestData = try JSONSerialization.data(withJSONObject: manifestObj, options: [.prettyPrinted, .sortedKeys])
    try manifestData.write(to: manifestURL)

    try await repo.signed(version: 1, languages: [.swift], ast: ast)

    let reg = try await repo.run {
      try await RegistryManager.loadAndVerify()
    }
    let ruleTreeHash = try #require(reg.rules["no-fatal-error"])

    let ruleDir = repo.repoURL.appendingPathComponent("invariants/rules/no-fatal-error")
    let runner = RuleRunner()

    let manifest = try ManifestParser.parse(data: manifestData)
    try await verifyFixtures(
      manifest: manifest,
      ruleDir: ruleDir,
      ruleTreeHash: ruleTreeHash,
      ast: ast
    )

    let cleanReq = RuleRequest(
      mode: "repo",
      repoRoot: repo.repoURL.path,
      ruleDir: ruleDir.path,
      files: ["App/SafeService.swift"],
      unitFiles: ["main": ["App/SafeService.swift"]],
      ast: ast
    )
    let cleanViolations = try await runner.execute(
      target: .swift,
      ruleDirectory: ruleDir,
      ruleTreeHash: ruleTreeHash,
      request: cleanReq
    )
    #expect(cleanViolations.isEmpty)

    let violatingFileURL = repo.repoURL.appendingPathComponent("App/CrashingService.swift")
    try Data("func dangerousOperation() { fatalError(\"boom\") }\n".utf8).write(to: violatingFileURL)

    let violatingReq = RuleRequest(
      mode: "repo",
      repoRoot: repo.repoURL.path,
      ruleDir: ruleDir.path,
      files: ["App/SafeService.swift", "App/CrashingService.swift"],
      unitFiles: ["main": ["App/SafeService.swift", "App/CrashingService.swift"]],
      ast: ast
    )
    let repoViolations = try await runner.execute(
      target: .swift,
      ruleDirectory: ruleDir,
      ruleTreeHash: ruleTreeHash,
      request: violatingReq
    )
    #expect(repoViolations.count == 1)
    let first = try #require(repoViolations.first)
    #expect(first.code == "NO-FATAL-ERROR")
    #expect(first.file.hasSuffix("CrashingService.swift"))
    #expect(first.fix == "throw AppError.unrecoverable")

    try Data("func dangerousOperation() { /* safe */ }\n".utf8).write(to: violatingFileURL)

    let resolvedViolations = try await runner.execute(
      target: .swift,
      ruleDirectory: ruleDir,
      ruleTreeHash: ruleTreeHash,
      request: violatingReq
    )
    #expect(resolvedViolations.isEmpty)
  }

  @Test("E2E Simulation: Creates repo with dual-target rule (Swift + TypeScript), enforcing both simultaneously")
  func e2eDualTargetRuleSimultaneously() async throws {
    let repo = try await TestRepo()

    var ast = ASTConfig()
    ast[SwiftLanguage.self] = ["main": SwiftLanguage.Config(indexStore: "build/Index.noindex/DataStore")]
    ast[TypeScriptLanguage.self] = ["main": TypeScriptLanguage.Config(tsconfig: "tsconfig.json")]

    #expect(ast.isConfigured(.swift))
    #expect(ast.isConfigured(.ts))

    let ruleSwiftBody = """
      let sources = SourceFileCollection(files: ctx.files, repoRoot: ctx.repoRoot)
      return sources.calls(named: "eval").violations(
          code: "NO-EVAL",
          message: { _ in "eval() is strictly forbidden across all platforms." },
          fix: "use static parsing"
      )
      """

    let ruleTsBody = """
      const violations = [];
      for (const filePath of ctx.files) {
        const sf = ctx.sourceFile(filePath);
        const text = sf?.getFullText() ?? "";
        if (text.includes("eval(")) {
          violations.push({
            code: "NO-EVAL",
            file: filePath,
            line: 1,
            column: 1,
            message: "eval() is strictly forbidden across all platforms.",
            fix: "use static parsing"
          });
        }
      }
      return violations;
      """

    try repo.withRule(
      "no-eval",
      targets: [.swift, .ts],
      ruleSwiftBody: ruleSwiftBody,
      ruleTsBody: ruleTsBody,
      extraFiles: [
        "tsconfig.json":
          "{\n  \"compilerOptions\": { \"target\": \"ES2022\", \"module\": \"NodeNext\" },\n  \"include\": [\"src/**/*.ts\"]\n}\n",
        "Sources/App/Engine.swift": "struct Engine { let power = 100 }\n",
        "src/parser/engine.ts": "export const engine = { power: 100 };\n",
      ]
    )

    let swiftFailFixture = repo.repoURL.appendingPathComponent(
      "invariants/rules/no-eval/should_fail/swift/case1.swift")
    try Data("func run() { eval(\"bad\") } // expect: NO-EVAL\n".utf8).write(to: swiftFailFixture)

    let tsFailFixture = repo.repoURL.appendingPathComponent(
      "invariants/rules/no-eval/should_fail/ts/case1.ts")
    try Data("eval('bad'); // expect: NO-EVAL\n".utf8).write(to: tsFailFixture)

    let manifestURL = repo.repoURL.appendingPathComponent("invariants/rules/no-eval/manifest.json")
    let manifestObj: [String: Any] = [
      "id": "no-eval",
      "summary": "Forbid dynamic eval across platforms",
      "targets": ["swift", "ts"],
      "scope": [
        "swift": ["main": ["include": ["Sources/**/*.swift"]]],
        "ts": ["main": ["include": ["src/**/*.ts"]]],
      ],
      "codes": ["NO-EVAL": "eval() is strictly forbidden"],
    ]
    let manifestData = try JSONSerialization.data(withJSONObject: manifestObj, options: [.prettyPrinted, .sortedKeys])
    try manifestData.write(to: manifestURL)

    try await repo.signed(version: 1, languages: [.swift, .ts], ast: ast)

    let reg = try await repo.run {
      try await RegistryManager.loadAndVerify()
    }
    let ruleTreeHash = try #require(reg.rules["no-eval"])

    let ruleDir = repo.repoURL.appendingPathComponent("invariants/rules/no-eval")
    let runner = RuleRunner()

    let manifest = try ManifestParser.parse(data: manifestData)
    try await verifyFixtures(
      manifest: manifest,
      ruleDir: ruleDir,
      ruleTreeHash: ruleTreeHash,
      ast: ast
    )

    let swiftCleanReq = RuleRequest(
      mode: "repo",
      repoRoot: repo.repoURL.path,
      ruleDir: ruleDir.path,
      files: ["Sources/App/Engine.swift"],
      unitFiles: ["main": ["Sources/App/Engine.swift"]],
      ast: ast
    )
    let swiftCleanViolations = try await runner.execute(
      target: .swift,
      ruleDirectory: ruleDir,
      ruleTreeHash: ruleTreeHash,
      request: swiftCleanReq
    )
    #expect(swiftCleanViolations.isEmpty)

    let tsCleanReq = RuleRequest(
      mode: "repo",
      repoRoot: repo.repoURL.path,
      ruleDir: ruleDir.path,
      files: ["src/parser/engine.ts"],
      unitFiles: ["main": ["src/parser/engine.ts"]],
      ast: ast
    )
    let tsCleanViolations = try await runner.execute(
      target: .ts,
      ruleDirectory: ruleDir,
      ruleTreeHash: ruleTreeHash,
      request: tsCleanReq
    )
    #expect(tsCleanViolations.isEmpty)

    let violatingSwiftURL = repo.repoURL.appendingPathComponent("Sources/App/Dangerous.swift")
    try Data("func evil() { eval(\"swift_leak\") }\n".utf8).write(to: violatingSwiftURL)

    let violatingTsURL = repo.repoURL.appendingPathComponent("src/parser/dangerous.ts")
    try Data("eval('ts_leak');\n".utf8).write(to: violatingTsURL)

    let swiftViolatingReq = RuleRequest(
      mode: "repo",
      repoRoot: repo.repoURL.path,
      ruleDir: ruleDir.path,
      files: ["Sources/App/Engine.swift", "Sources/App/Dangerous.swift"],
      unitFiles: ["main": ["Sources/App/Engine.swift", "Sources/App/Dangerous.swift"]],
      ast: ast
    )
    let swiftViolations = try await runner.execute(
      target: .swift,
      ruleDirectory: ruleDir,
      ruleTreeHash: ruleTreeHash,
      request: swiftViolatingReq
    )
    #expect(swiftViolations.count == 1)
    let swiftV = try #require(swiftViolations.first)
    #expect(swiftV.code == "NO-EVAL")
    #expect(swiftV.file.hasSuffix("Dangerous.swift"))

    let tsViolatingReq = RuleRequest(
      mode: "repo",
      repoRoot: repo.repoURL.path,
      ruleDir: ruleDir.path,
      files: ["src/parser/engine.ts", "src/parser/dangerous.ts"],
      unitFiles: ["main": ["src/parser/engine.ts", "src/parser/dangerous.ts"]],
      ast: ast
    )
    let tsViolations = try await runner.execute(
      target: .ts,
      ruleDirectory: ruleDir,
      ruleTreeHash: ruleTreeHash,
      request: tsViolatingReq
    )
    #expect(tsViolations.count == 1)
    let tsV = try #require(tsViolations.first)
    #expect(tsV.code == "NO-EVAL")
    #expect(tsV.file.hasSuffix("dangerous.ts"))

    try Data("func evil() { /* fixed */ }\n".utf8).write(to: violatingSwiftURL)
    try Data("export const fixed = true;\n".utf8).write(to: violatingTsURL)

    let swiftResolved = try await runner.execute(
      target: .swift,
      ruleDirectory: ruleDir,
      ruleTreeHash: ruleTreeHash,
      request: swiftViolatingReq
    )
    #expect(swiftResolved.isEmpty)

    let tsResolved = try await runner.execute(
      target: .ts,
      ruleDirectory: ruleDir,
      ruleTreeHash: ruleTreeHash,
      request: tsViolatingReq
    )
    #expect(tsResolved.isEmpty)
  }

  private func verifyFixtures(
    manifest: RuleManifest,
    ruleDir: URL,
    ruleTreeHash: String,
    ast: ASTConfig
  ) async throws {
    let runner = RuleRunner()
    try await FixtureExecutionService.verifyAllFixtures(
      manifest: manifest,
      ruleDirectory: ruleDir,
      ruleTreeHash: ruleTreeHash,
      ast: ast,
      runner: runner
    )
  }
}
