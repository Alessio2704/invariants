import CryptoKit
import Foundation
import LocalAuthentication

@testable import Core

/// Fluent test repository builder for Scenario and Security tests.
final class TestRepo: @unchecked Sendable {
  let repoURL: URL
  let rootURL: URL
  let keyURL: URL
  let pubKeyURL: URL
  let environment: SystemEnvironment

  init() async throws {
    let fm = FileManager.default
    let baseDir = fm.temporaryDirectory.appendingPathComponent("test_repo_\(UUID().uuidString)")
    self.repoURL = baseDir.appendingPathComponent("repo")
    self.rootURL = baseDir.appendingPathComponent("fake_root")
    self.keyURL = baseDir.appendingPathComponent("id_p256")
    self.pubKeyURL = baseDir.appendingPathComponent("id_p256.pub")

    try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
    try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)

    _ = try await SubprocessRunner.run(
      binary: .git, arguments: ["-C", repoURL.path, "init", "-b", "main"])
    _ = try await SubprocessRunner.run(
      binary: .git, arguments: ["-C", repoURL.path, "config", "user.name", "Test User"])
    _ = try await SubprocessRunner.run(
      binary: .git,
      arguments: ["-C", repoURL.path, "config", "user.email", "test@invariants.local"])

    try SigningClient.generateThrowawayKey(at: keyURL)

    let pubKeyStr = try pubKeyURL.readTrimmedUTF8()

    let signersURL = RepoLocator.withRepoRoot(repoURL) {
      RegistryManager.allowedSignersURL()
    }
    try fm.createDirectory(at: signersURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let signersContent = "* namespaces=\"invariants\" \(pubKeyStr)\n"
    try Data(signersContent.utf8).write(to: signersURL)

    self.environment = SystemEnvironment(rootURL: rootURL)
  }

  deinit {
    try? FileManager.default.removeItem(at: repoURL.deletingLastPathComponent())
  }

  /// Adds a rule with manifest, rule source, and red/green fixtures.
  @discardableResult
  func withRule(
    _ id: String,
    targets: [TargetLanguage] = [.swift],
    ruleSwiftBody: String = "return []",
    ruleTsBody: String = "return [];",
    extraFiles: [String: String] = [:]
  ) throws -> TestRepo {
    let fm = FileManager.default
    let ruleDir = repoURL.appendingPathComponent("invariants/rules/\(id)")
    try fm.createDirectory(at: ruleDir, withIntermediateDirectories: true)

    var scopeDict: [String: Any] = [:]
    for t in targets {
      scopeDict[t.rawValue] = ["include": [t == .swift ? "**/*.swift" : "**/*.ts"]]
    }

    let manifestObj: [String: Any] = [
      "id": id,
      "summary": "Rule \(id)",
      "targets": targets.map { $0.rawValue },
      "scope": scopeDict,
      "codes": ["TEST-01": "Test violation"],
    ]
    let manifestData = try JSONSerialization.data(withJSONObject: manifestObj, options: [.prettyPrinted, .sortedKeys])
    try manifestData.write(to: ruleDir.appendingPathComponent("manifest.json"))

    for t in targets {
      let passDir = ruleDir.appendingPathComponent("should_pass/\(t.rawValue)")
      let failDir = ruleDir.appendingPathComponent("should_fail/\(t.rawValue)")
      try fm.createDirectory(at: passDir, withIntermediateDirectories: true)
      try fm.createDirectory(at: failDir, withIntermediateDirectories: true)

      if t == .swift {
        let ruleSrc = """
          import InvariantKit

          @main
          struct \(id.replacingOccurrences(of: "-", with: "_").capitalized)Rule: SwiftRule {
              func check(_ ctx: RuleContext) throws(RuleError) -> [Violation] {
                  \(ruleSwiftBody)
              }
          }
          """
        try Data(ruleSrc.utf8).write(to: ruleDir.appendingPathComponent("rule.swift"))
        try Data("// pass\n".utf8).write(to: passDir.appendingPathComponent("case1.swift"))
        try Data("// fail\n// expect: TEST-01\n".utf8).write(to: failDir.appendingPathComponent("case1.swift"))
      } else if t == .ts {
        let ruleSrc = """
          import { defineRule } from "@invariants/kit";

          export default defineRule({
            check(ctx) {
              \(ruleTsBody)
            },
          });
          """
        try Data(ruleSrc.utf8).write(to: ruleDir.appendingPathComponent("rule.ts"))
        try Data("// pass\n".utf8).write(to: passDir.appendingPathComponent("case1.ts"))
        try Data("// fail\n// expect: TEST-01\n".utf8).write(to: failDir.appendingPathComponent("case1.ts"))
      }
    }

    for (relPath, content) in extraFiles {
      let fileURL = repoURL.appendingPathComponent(relPath)
      try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(content.utf8).write(to: fileURL)
    }

    return self
  }

  static var defaultLanguages: LanguagesConfig {
    var config = LanguagesConfig()
    config[SwiftLanguage.self] = SwiftLanguage.Config(indexStore: "build/Index.noindex/DataStore")
    return config
  }

  /// Signs the registry and commits it.
  @discardableResult
  func signed(
    version: Int = 1,
    engine: String = EngineVersion.defaultRange,
    defaultBranch: String = "main",
    languages: LanguagesConfig = TestRepo.defaultLanguages
  ) async throws -> TestRepo {
    try await RepoLocator.withRepoRoot(repoURL) {
      var ruleMap: [String: String] = [:]

      let rulesBaseDir = repoURL.appendingPathComponent("invariants/rules")
      if let dirs = try? FileManager.default.contentsOfDirectory(atPath: rulesBaseDir.path) {
        for dir in dirs where !dir.hasPrefix(".") {
          let hash = try await FingerprintEngine.computeFingerprint(ruleId: dir)
          ruleMap[dir] = hash
        }
      }

      let reg = Registry(
        version: version,
        engine: engine,
        defaultBranch: defaultBranch,
        languages: languages,
        rules: ruleMap
      )

      try await RegistryManager.saveAndSign(
        registry: reg,
        keyURL: keyURL
      )

      try await GitClient.commit(
        paths: ["."],
        message: "Signed registry v\(version)"
      )
    }

    return self
  }

  /// Runs an async operation with this test repo set as the active RepoLocator.current.
  @discardableResult
  func run<T>(_ operation: () async throws -> T) async rethrows -> T {
    try await RepoLocator.withRepoRoot(repoURL, operation: operation)
  }

  /// Runs a synchronous operation with this test repo set as the active RepoLocator.current.
  @discardableResult
  func run<T>(_ operation: () throws -> T) rethrows -> T {
    try RepoLocator.withRepoRoot(repoURL, operation: operation)
  }
}

extension Registry {
  static func forTesting(
    version: Int = 1,
    engine: String = "^1.0.0",
    defaultBranch: String = "main",
    languages: LanguagesConfig = TestRepo.defaultLanguages,
    rules: [String: String] = [:],
    signersHash: String? = nil
  ) -> Registry {
    Registry(
      version: version,
      engine: engine,
      defaultBranch: defaultBranch,
      languages: languages,
      rules: rules,
      signersHash: signersHash
    )
  }
}

extension BiometricAuthToken {
  static func forTesting(
    context: LAContext = LAContext(),
    authorizedAt: Date = Date(),
    expirationInterval: TimeInterval = 30.0
  ) -> BiometricAuthToken {
    BiometricAuthToken(
      context: context,
      authorizedAt: authorizedAt,
      expirationInterval: expirationInterval
    )
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
