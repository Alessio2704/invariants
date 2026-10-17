import Foundation
import Testing

@testable import InvariantCore

@Suite("Fingerprint Engine", .tags(.unit))
struct FingerprintTests {
  @Test("Tree hash calculation includes untracked files and excludes ignored files")
  func fingerprintTreeHash() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fm = FileManager.default
    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    // Initialize git repo
    let runner = SubprocessRunner()
    _ = try await runner.run(executableURL: SystemEnvironment.gitURL, arguments: ["-C", tmpDir.path, "init"])

    let ruleDir = tmpDir.appendingPathComponent("invariants/rules/toy")
    try fm.createDirectory(at: ruleDir, withIntermediateDirectories: true)

    let manifestURL = ruleDir.appendingPathComponent("manifest.json")
    try Data("{\"id\":\"toy\"}".utf8).write(to: manifestURL)

    let gitignoreURL = tmpDir.appendingPathComponent(".gitignore")
    try Data("*.ignored\n".utf8).write(to: gitignoreURL)

    let engine = FingerprintEngine()
    let hash1 = try await engine.computeFingerprint(repoRoot: tmpDir, ruleId: "toy")
    #expect(hash1.count == 40)

    // Adding an ignored file should not change the fingerprint
    let ignoredFile = ruleDir.appendingPathComponent("scratch.ignored")
    try Data("some ignored content".utf8).write(to: ignoredFile)

    let hash2 = try await engine.computeFingerprint(repoRoot: tmpDir, ruleId: "toy")
    #expect(hash1 == hash2)

    // Adding an unignored untracked file MUST change the fingerprint
    let trackedFile = ruleDir.appendingPathComponent("rule.swift")
    try Data("// Swift rule".utf8).write(to: trackedFile)

    let hash3 = try await engine.computeFingerprint(repoRoot: tmpDir, ruleId: "toy")
    #expect(hash3 != hash1)
  }
}
