import Foundation
import Testing

@testable import InvariantCore

@Suite("Engine Tool Management: Signers, Self-Update & Uninstall", .tags(.scenario))
struct ToolManagementTests {
  @Test("Signers management: add, list, and remove keys from allowed_signers")
  func signersAddListRemove() async throws {
    let repo = try await TestRepo()
    let signersURL = repo.environment.allowedSignersURL
    let client = SudoClient()

    // 1. Initial content from TestRepo contains owner key
    let initial = try String(contentsOf: signersURL, encoding: .utf8)
    #expect(initial.contains("owner"))

    // 2. Add coworker key
    let coworkerKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleCoworkerKey coworker@plans"
    let newEntry = "alice namespaces=\"git,invariants\" \(coworkerKey)\n"
    try await client.writePrivilegedFile(at: signersURL, content: newEntry, append: true)

    let updated = try String(contentsOf: signersURL, encoding: .utf8)
    #expect(updated.contains("alice"))
    #expect(updated.contains("coworker@plans"))

    // 3. Remove coworker key by matching "alice"
    let lines = updated.split(separator: "\n").map(String.init)
    let filtered = lines.filter { !$0.contains("alice") }.joined(separator: "\n") + "\n"
    try await client.writePrivilegedFile(at: signersURL, content: filtered, append: false)

    let afterRemoval = try String(contentsOf: signersURL, encoding: .utf8)
    #expect(!afterRemoval.contains("alice"))
    #expect(afterRemoval.contains("owner"))
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

    let env = SystemEnvironment(customRoot: rootURL, customBin: binURL)
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

    let env = SystemEnvironment(customRoot: rootURL, customBin: binURL)
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
