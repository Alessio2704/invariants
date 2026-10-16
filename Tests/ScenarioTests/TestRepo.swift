import Foundation

@testable import InvariantCore

/// Fluent test repository builder for Scenario and Security tests.
final class TestRepo: @unchecked Sendable {
  let repoURL: URL
  let rootURL: URL
  let keyURL: URL
  let pubKeyURL: URL
  let environment: SystemEnvironment
  private let gitClient: GitClient
  private let sshClient: SSHKeygenClient
  private let registryManager: RegistryManager

  init() async throws {
    let fm = FileManager.default
    let baseDir = fm.temporaryDirectory.appendingPathComponent("test_repo_\(UUID().uuidString)")
    self.repoURL = baseDir.appendingPathComponent("repo")
    self.rootURL = baseDir.appendingPathComponent("fake_root")
    self.keyURL = baseDir.appendingPathComponent("id_ed25519")
    self.pubKeyURL = baseDir.appendingPathComponent("id_ed25519.pub")

    try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
    try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)

    let runner = SubprocessRunner()
    _ = try await runner.run(
      executableURL: SubprocessRunner.gitURL, arguments: ["-C", repoURL.path, "init", "-b", "main"])
    _ = try await runner.run(
      executableURL: SubprocessRunner.gitURL, arguments: ["-C", repoURL.path, "config", "user.name", "Test User"])
    _ = try await runner.run(
      executableURL: SubprocessRunner.gitURL,
      arguments: ["-C", repoURL.path, "config", "user.email", "test@invariants.local"])

    self.sshClient = SSHKeygenClient()
    try await sshClient.generateThrowawayKey(at: keyURL)

    let pubKeyData = try Data(contentsOf: pubKeyURL)
    let pubKeyStr = (String(bytes: pubKeyData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

    let signersURL = RegistryManager.allowedSignersURL(repoRoot: repoURL)
    try fm.createDirectory(at: signersURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let signersContent = "* namespaces=\"invariants\" \(pubKeyStr)\n"
    try Data(signersContent.utf8).write(to: signersURL)

    self.environment = SystemEnvironment(customRoot: rootURL)
    self.gitClient = GitClient()
    self.registryManager = RegistryManager(environment: environment, sshClient: sshClient)
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

  /// Signs the registry and commits it.
  @discardableResult
  func signed(repo: String = "test-repo", version: Int = 1) async throws -> TestRepo {
    let fingerprintEngine = FingerprintEngine(gitClient: gitClient)
    var ruleMap: [String: String] = [:]

    let rulesBaseDir = repoURL.appendingPathComponent("invariants/rules")
    if let dirs = try? FileManager.default.contentsOfDirectory(atPath: rulesBaseDir.path) {
      for dir in dirs where !dir.hasPrefix(".") {
        let hash = try await fingerprintEngine.computeFingerprint(repoRoot: repoURL, ruleId: dir)
        ruleMap[dir] = hash
      }
    }

    let reg = Registry(
      repo: repo,
      version: version,
      engine: "^1.0.0",
      rules: ruleMap
    )

    try await registryManager.saveAndSign(
      registry: reg,
      repoRoot: repoURL,
      keyURL: keyURL
    )

    try await gitClient.commit(
      repoRoot: repoURL,
      paths: ["."],
      message: "Signed registry v\(version)"
    )

    return self
  }
}
