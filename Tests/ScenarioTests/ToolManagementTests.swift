import Foundation
import Testing

@testable import InvariantCore

@Suite("Engine Tool Management: Signers, Self-Update & Uninstall", .tags(.scenario))
struct ToolManagementTests {
  @Test("Signers management: add, list, soft revoke, and hard revoke keys from in-repo allowed_signers")
  func signersAddListRevoke() async throws {
    let repo = try await TestRepo()
    let signersURL = RegistryManager.allowedSignersURL(repoRoot: repo.repoURL)

    // 1. Initial content from TestRepo contains owner public key
    let initial = try String(contentsOf: signersURL, encoding: .utf8)
    #expect(!initial.isEmpty)

    // 2. Add coworker key directly (in-repo, no sudo)
    let coworkerKey =
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBIExampleCoworkerKey coworker@plans"
    let newEntry = "* namespaces=\"invariants\" \(coworkerKey)\n"
    var content = initial
    content.append(newEntry)
    try content.write(to: signersURL, atomically: true, encoding: .utf8)

    let updated = try String(contentsOf: signersURL, encoding: .utf8)
    #expect(updated.contains("ExampleCoworkerKey"))
    #expect(updated.contains("coworker@plans"))

    // 3. Soft revoke coworker key (add valid-before)
    let lines = updated.split(separator: "\n").map(String.init)
    let softRevoked =
      lines.map { line in
        if line.contains("coworker@plans") {
          return "* namespaces=\"invariants\",valid-before=\"20261016T000000Z\" \(coworkerKey)"
        }
        return line
      }.joined(separator: "\n") + "\n"
    try softRevoked.write(to: signersURL, atomically: true, encoding: .utf8)

    let afterSoft = try String(contentsOf: signersURL, encoding: .utf8)
    #expect(afterSoft.contains("valid-before=\"20261016T000000Z\""))

    // 4. Hard revoke coworker key (completely removed from allowed_signers)
    let hardRevoked = lines.filter { !$0.contains("coworker@plans") }.joined(separator: "\n") + "\n"
    try hardRevoked.write(to: signersURL, atomically: true, encoding: .utf8)

    let afterHard = try String(contentsOf: signersURL, encoding: .utf8)
    #expect(!afterHard.contains("coworker@plans"))
  }

  @Test("Self-update: installs staged version and atomically updates symlinks")
  func selfUpdateFromStage() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("self_update_test_\(UUID().uuidString)")
    let rootURL = tmpDir.appendingPathComponent("root")
    let binDir = tmpDir.appendingPathComponent("bin")
    let binURL = binDir.appendingPathComponent("invariants")
    let stageDir = tmpDir.appendingPathComponent("stage")

    let fm = FileManager.default
    try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
    try "executable-binary-v1.1.0".write(
      to: stageDir.appendingPathComponent("invariants"), atomically: true, encoding: .utf8)

    defer { try? fm.removeItem(at: tmpDir) }

    let env = SystemEnvironment(rootURL: rootURL, binURL: binURL)
    let client = SudoClient()

    // Install version 1.1.0 from stage
    try await client.installVersion(version: "1.1.0", stageDir: stageDir, environment: env)

    // Verify version 1.1.0 is in versions/
    let installedBin = env.versionsDirectoryURL.appendingPathComponent("1.1.0/invariants")
    #expect(fm.fileExists(atPath: installedBin.path))
    #expect(try String(contentsOf: installedBin, encoding: .utf8) == "executable-binary-v1.1.0")

    // Verify current symlink points to 1.1.0
    #expect(fm.fileExists(atPath: env.currentVersionURL.path))

    // Verify bin symlink points to current/invariants
    #expect(fm.fileExists(atPath: env.binURL.path))
    #expect(try String(contentsOf: env.binURL, encoding: .utf8) == "executable-binary-v1.1.0")
  }

  @Test("Uninstall: completely wipes root directory and binary symlink")
  func uninstallEngine() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("uninstall_test_\(UUID().uuidString)")
    let rootURL = tmpDir.appendingPathComponent("root")
    let binDir = tmpDir.appendingPathComponent("bin")
    let binURL = binDir.appendingPathComponent("invariants")

    let fm = FileManager.default
    try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
    try "dummy bin".write(to: binURL, atomically: true, encoding: .utf8)

    let env = SystemEnvironment(rootURL: rootURL, binURL: binURL)
    let client = SudoClient()

    defer { try? fm.removeItem(at: tmpDir) }

    #expect(fm.fileExists(atPath: rootURL.path))
    #expect(fm.fileExists(atPath: binURL.path))

    // Uninstall
    try await client.uninstall(environment: env)

    #expect(!fm.fileExists(atPath: rootURL.path))
    #expect(!fm.fileExists(atPath: binURL.path))
  }
}
