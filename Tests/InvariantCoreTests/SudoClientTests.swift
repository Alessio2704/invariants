import Foundation
import Testing

@testable import InvariantCore

@Suite("SudoClient & Elevation Detection", .tags(.unit))
struct SudoClientTests {
  @Test("requiresElevation detects writable user directories without sudo")
  func writableDirectoryRequiresNoElevation() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let client = SudoClient()
    let testFileURL = tmpDir.appendingPathComponent("floors/test-repo")

    // The parent tmpDir is writable by the user, so requiresElevation should be false
    #expect(!client.requiresElevation(for: testFileURL))
  }

  @Test("requiresElevation detects root-owned directories requiring sudo")
  func rootDirectoryRequiresElevation() {
    let client = SudoClient()
    let protectedFileURL = URL(fileURLWithPath: "/usr/local/invariants/floors/test-repo")

    // /usr/local is owned by root:wheel and not writable by regular user
    #expect(client.requiresElevation(for: protectedFileURL))
  }

  @Test("requiresElevation detects non-writable directories dynamically")
  func readOnlyDirectoryRequiresElevation() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let readOnlySubdir = tmpDir.appendingPathComponent("readonly")
    try FileManager.default.createDirectory(at: readOnlySubdir, withIntermediateDirectories: true)
    defer {
      // Restore permissions before cleanup
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnlySubdir.path)
      try? FileManager.default.removeItem(at: tmpDir)
    }

    // Set permissions to 0o555 (read + execute, no write)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnlySubdir.path)

    let client = SudoClient()
    let targetFile = readOnlySubdir.appendingPathComponent("file.txt")

    #expect(client.requiresElevation(for: targetFile))
  }

  @Test("writeFloor writes version to writable directory and overwrites correctly")
  func writeFloorInSandbox() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let env = SystemEnvironment(customRoot: tmpDir)
    let client = SudoClient()

    // 1. Write initial floor version
    try await client.writeFloor(repo: "plans-app", version: 1, environment: env)

    let floorFile = env.floorsDirectoryURL.appendingPathComponent("plans-app")
    #expect(FileManager.default.fileExists(atPath: floorFile.path))

    let content1 = try String(contentsOf: floorFile, encoding: .utf8)
    #expect(content1 == "1\n")

    // 2. Overwrite with bumped floor version
    try await client.writeFloor(repo: "plans-app", version: 2, environment: env)

    let content2 = try String(contentsOf: floorFile, encoding: .utf8)
    #expect(content2 == "2\n")
  }
}
