import CryptoKit
import Foundation
import Testing

@testable import Core
@testable import Managers
@testable import Workflows

/// Isolated test project fixture with a full Git repository, Swift and TS sources, and 4 signed rules (2 Swift, 2 TS).
final class AuditProjectFixture: @unchecked Sendable {
  let baseDir: URL
  let repoURL: URL
  let fakeRootURL: URL
  let sandboxPrefixURL: URL
  let keysDir: URL

  // Cryptographic keys
  let ownerKey: URL
  let coworkerKey: URL
  let contractorKey: URL
  let rogueAgentKey: URL

  // Public key strings
  let ownerPub: String
  let coworkerPub: String
  let contractorPub: String
  let rogueAgentPub: String

  init() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("sec_attack_\(UUID().uuidString)")
    self.baseDir = base
    self.repoURL = base.appendingPathComponent("app-repo")
    self.fakeRootURL = base.appendingPathComponent("fake_root")
    self.sandboxPrefixURL = base.appendingPathComponent("prefix")
    self.keysDir = base.appendingPathComponent("keys")

    self.ownerKey = keysDir.appendingPathComponent("owner_p256")
    self.coworkerKey = keysDir.appendingPathComponent("coworker_p256")
    self.contractorKey = keysDir.appendingPathComponent("contractor_p256")
    self.rogueAgentKey = keysDir.appendingPathComponent("rogue_agent_p256")

    try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
    try fm.createDirectory(at: fakeRootURL, withIntermediateDirectories: true)
    try fm.createDirectory(at: sandboxPrefixURL, withIntermediateDirectories: true)
    try fm.createDirectory(at: keysDir, withIntermediateDirectories: true)

    try SigningClient.generateThrowawayKey(at: ownerKey)
    try SigningClient.generateThrowawayKey(at: coworkerKey)
    try SigningClient.generateThrowawayKey(at: contractorKey)
    try SigningClient.generateThrowawayKey(at: rogueAgentKey)

    self.ownerPub = try keysDir.appendingPathComponent("owner_p256.pub").readTrimmedUTF8()
    self.coworkerPub = try keysDir.appendingPathComponent("coworker_p256.pub").readTrimmedUTF8()
    self.contractorPub = try keysDir.appendingPathComponent("contractor_p256.pub").readTrimmedUTF8()
    self.rogueAgentPub = try keysDir.appendingPathComponent("rogue_agent_p256.pub").readTrimmedUTF8()

    _ = try await SubprocessRunner.run(
      binary: .git, arguments: ["-C", repoURL.path, "init", "-b", "main"])
    _ = try await SubprocessRunner.run(
      binary: .git, arguments: ["-C", repoURL.path, "config", "user.name", "Security Auditor"])
    _ = try await SubprocessRunner.run(
      binary: .git, arguments: ["-C", repoURL.path, "config", "user.email", "auditor@invariants.local"])

    try setupProjectSources()
    try setupRules()
    try await signInitialRegistry()
  }

  deinit {
    try? FileManager.default.removeItem(at: baseDir)
  }

  /// Runs an async closure within the context of this test repository.
  @discardableResult
  func run<T>(_ operation: () async throws -> T) async rethrows -> T {
    try await RepoLocator.withRepoRoot(repoURL, operation: operation)
  }

  /// Runs a synchronous closure within the context of this test repository.
  @discardableResult
  func run<T>(_ operation: () throws -> T) rethrows -> T {
    try RepoLocator.withRepoRoot(repoURL, operation: operation)
  }

  /// Verifies that all 4 active rules and baseline repo checks pass end-to-end.
  func verifyBaseline() async throws {
    try await run {
      let reg = try await RegistryManager.loadAndVerify()
      #expect(reg.version == 1)
      #expect(reg.rules.count == 4)

      let floor = try await FloorGuard.checkHistory(currentVersion: 1)
      #expect(floor == 1)
      try await FloorGuard.checkSignerAncestry(currentRegistry: reg)

      let passed = try await CheckWorkflow.execute(json: false, prePush: false)
      #expect(passed)
    }
  }

  // MARK: - Setup Helpers

  private func setupProjectSources() throws {
    let fm = FileManager.default
    let appSourcesDir = repoURL.appendingPathComponent("Sources/App")
    try fm.createDirectory(at: appSourcesDir, withIntermediateDirectories: true)

    let packageSwift = """
      // swift-tools-version: 6.0
      import PackageDescription
      let package = Package(
          name: "AuditApp",
          products: [.library(name: "App", targets: ["App"])],
          targets: [.target(name: "App")]
      )
      """
    try packageSwift.write(to: repoURL.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

    let appSwift = """
      public struct AppModel {
          public init() {}
          public func run() {}
      }
      """
    try appSwift.write(to: appSourcesDir.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)

    let networkSwift = """
      public struct NetworkService {
          public init() {}
          public func fetch() {}
      }
      """
    try networkSwift.write(to: appSourcesDir.appendingPathComponent("Network.swift"), atomically: true, encoding: .utf8)

    let webSrcDir = repoURL.appendingPathComponent("web/src")
    try fm.createDirectory(at: webSrcDir, withIntermediateDirectories: true)

    let tsconfig = """
      {
        "compilerOptions": {
          "target": "ES2022",
          "module": "NodeNext"
        },
        "include": ["src/**/*"]
      }
      """
    try tsconfig.write(to: repoURL.appendingPathComponent("web/tsconfig.json"), atomically: true, encoding: .utf8)
    try "export const appName = 'AuditApp';\n".write(
      to: webSrcDir.appendingPathComponent("index.ts"), atomically: true, encoding: .utf8)
    try "export function render(): string { return '<div>OK</div>'; }\n".write(
      to: webSrcDir.appendingPathComponent("ui.ts"), atomically: true, encoding: .utf8)
  }

  private func setupRules() throws {
    let fm = FileManager.default

    // Swift Rule 1: no-print-in-app
    try createSwiftRule(
      id: "no-print-in-app",
      summary: "Forbid print() in application sources",
      callName: "print",
      code: "NO-PRINT",
      message: "print() calls are forbidden in production code."
    )

    // Swift Rule 2: no-debug-dump
    try createSwiftRule(
      id: "no-debug-dump",
      summary: "Forbid dump() in application sources",
      callName: "dump",
      code: "NO-DUMP",
      message: "dump() calls are forbidden in production code."
    )

    // TS Rule 1: no-db-in-ui
    try createTsRule(
      id: "no-db-in-ui",
      summary: "Forbid direct database imports in UI components",
      triggerSubstring: "from './db'",
      code: "NO-DB-UI",
      message: "Direct DB imports forbidden in UI."
    )

    // TS Rule 2: no-raw-eval
    try createTsRule(
      id: "no-raw-eval",
      summary: "Forbid eval in web components",
      triggerSubstring: "eval(",
      code: "NO-EVAL",
      message: "eval() is strictly forbidden."
    )

    // allowed_signers with owner key
    let signersURL = repoURL.appendingPathComponent("invariants/allowed_signers")
    try fm.createDirectory(at: signersURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let signersContent = "* namespaces=\"invariants\" \(ownerPub)\n"
    try signersContent.write(to: signersURL, atomically: true, encoding: .utf8)
  }

  private func createSwiftRule(
    id: String,
    summary: String,
    callName: String,
    code: String,
    message: String
  ) throws {
    let fm = FileManager.default
    let ruleDir = repoURL.appendingPathComponent("invariants/rules/\(id)")
    let passDir = ruleDir.appendingPathComponent("should_pass/swift")
    let failDir = ruleDir.appendingPathComponent("should_fail/swift")
    try fm.createDirectory(at: passDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: failDir, withIntermediateDirectories: true)

    let manifestObj: [String: Any] = [
      "id": id,
      "summary": summary,
      "targets": ["swift"],
      "scope": ["swift": ["include": ["Sources/**/*.swift"]]],
      "codes": [code: message],
    ]
    let manifestData = try JSONSerialization.data(withJSONObject: manifestObj, options: [.prettyPrinted, .sortedKeys])
    try manifestData.write(to: ruleDir.appendingPathComponent("manifest.json"))

    let structName = id.split(separator: "-").map { $0.capitalized }.joined() + "Rule"
    let ruleSrc = """
      import InvariantKit

      @main
      struct \(structName): SwiftRule {
          func check(_ ctx: RuleContext) throws(RuleError) -> [Violation] {
              let sources = SourceFileCollection(files: ctx.files, repoRoot: ctx.repoRoot)
              return sources.calls(named: "\(callName)").violations(
                  code: "\(code)",
                  message: { _ in "\(message)" },
                  fix: "Clean"
              )
          }
      }
      """
    try ruleSrc.write(to: ruleDir.appendingPathComponent("rule.swift"), atomically: true, encoding: .utf8)
    try "struct CleanItem {}\n".write(
      to: passDir.appendingPathComponent("case1.swift"), atomically: true, encoding: .utf8)
    try "func bad() { \(callName)(\"bad\") } // expect: \(code)\n".write(
      to: failDir.appendingPathComponent("case1.swift"), atomically: true, encoding: .utf8)
  }

  private func createTsRule(
    id: String,
    summary: String,
    triggerSubstring: String,
    code: String,
    message: String
  ) throws {
    let fm = FileManager.default
    let ruleDir = repoURL.appendingPathComponent("invariants/rules/\(id)")
    let passDir = ruleDir.appendingPathComponent("should_pass/ts")
    let failDir = ruleDir.appendingPathComponent("should_fail/ts")
    try fm.createDirectory(at: passDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: failDir, withIntermediateDirectories: true)

    let manifestObj: [String: Any] = [
      "id": id,
      "summary": summary,
      "targets": ["ts"],
      "scope": ["ts": ["include": ["web/src/**/*.ts"]]],
      "codes": [code: message],
    ]
    let manifestData = try JSONSerialization.data(withJSONObject: manifestObj, options: [.prettyPrinted, .sortedKeys])
    try manifestData.write(to: ruleDir.appendingPathComponent("manifest.json"))

    let ruleTs = """
      import * as fs from "node:fs";
      import * as path from "node:path";
      import { defineRule } from "@invariants/kit";

      export default defineRule({
        check(ctx) {
          const violations = [];
          for (const file of ctx.files) {
            const absPath = path.isAbsolute(file) ? file : path.resolve(ctx.repoRoot, file);
            if (fs.existsSync(absPath)) {
              const text = fs.readFileSync(absPath, "utf8");
              if (text.includes("\(triggerSubstring)")) {
                violations.push({
                  code: "\(code)",
                  file,
                  line: 1,
                  column: 1,
                  message: "\(message)",
                  fix: "Clean",
                });
              }
            }
          }
          return violations;
        },
      });
      """
    try ruleTs.write(to: ruleDir.appendingPathComponent("rule.ts"), atomically: true, encoding: .utf8)
    try "export const clean = 1;\n".write(
      to: passDir.appendingPathComponent("case1.ts"), atomically: true, encoding: .utf8)
    try "// \(triggerSubstring) // expect: \(code)\n".write(
      to: failDir.appendingPathComponent("case1.ts"), atomically: true, encoding: .utf8)
  }

  private func signInitialRegistry() async throws {
    var ruleMap: [String: String] = [:]
    let rulesBaseDir = repoURL.appendingPathComponent("invariants/rules")
    let dirs = try FileManager.default.contentsOfDirectory(atPath: rulesBaseDir.path)
    for dir in dirs where !dir.hasPrefix(".") {
      let hash = try await run {
        try await FingerprintEngine.computeFingerprint(ruleId: dir)
      }
      ruleMap[dir] = hash
    }

    var languages = LanguagesConfig()
    languages[SwiftLanguage.self] = SwiftLanguage.Config(indexStore: "build/Index.noindex/DataStore")
    languages[TypeScriptLanguage.self] = TypeScriptLanguage.Config(tsconfig: ["web/tsconfig.json"])

    let reg = Registry(
      version: 1,
      engine: EngineVersion.defaultRange,
      defaultBranch: "main",
      languages: languages,
      rules: ruleMap
    )

    try await run {
      try await RegistryManager.saveAndSign(registry: reg, keyURL: ownerKey)
      try await GitClient.commit(paths: ["."], message: "Initial signed baseline v1")
    }
  }
}

extension SigningClient {
  /// Generates an in-memory / software P-256 key pair for automated test suites.
  static func generateThrowawayKey(at keyURL: URL) throws(SystemError) {
    let parent = keyURL.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    } catch {
      throw SystemError.fileIOError("Failed to create directory \(parent.path): \(error.localizedDescription)")
    }

    let privateKey = P256.Signing.PrivateKey()
    do {
      try privateKey.rawRepresentation.write(to: keyURL, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    } catch {
      throw SystemError.fileIOError("Failed to write test key to \(keyURL.path): \(error.localizedDescription)")
    }

    let pubString = SSHSIG.formatOpenSSHPublicKey(privateKey.publicKey)
    let pubURL = keyURL.appendingPathExtension("pub")
    do {
      try pubString.write(to: pubURL, atomically: true, encoding: .utf8)
    } catch {
      throw SystemError.fileIOError("Failed to write public key to \(pubURL.path): \(error.localizedDescription)")
    }
  }
}
