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

    #expect(!client.requiresElevation(for: testFileURL))
  }

  @Test("requiresElevation detects root-owned directories requiring sudo")
  func rootDirectoryRequiresElevation() {
    let client = SudoClient()
    let protectedFileURL = URL(fileURLWithPath: "/usr/local/invariants/floors/test-repo")

    #expect(client.requiresElevation(for: protectedFileURL))
  }

  @Test("requiresElevation detects non-writable directories dynamically")
  func readOnlyDirectoryRequiresElevation() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let readOnlySubdir = tmpDir.appendingPathComponent("readonly")
    try FileManager.default.createDirectory(at: readOnlySubdir, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnlySubdir.path)
      try? FileManager.default.removeItem(at: tmpDir)
    }

    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnlySubdir.path)

    let client = SudoClient()
    let targetFile = readOnlySubdir.appendingPathComponent("file.txt")

    #expect(client.requiresElevation(for: targetFile))
  }

  @Test("writePrivilegedFile writes, overwrites, and appends correctly")
  func writePrivilegedFileOperations() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let client = SudoClient()
    let testFile = tmpDir.appendingPathComponent("sub/test.txt")

    // 1. Initial write
    try await client.writePrivilegedFile(at: testFile, content: "Line 1\n", append: false)
    #expect(try String(contentsOf: testFile, encoding: .utf8) == "Line 1\n")

    // 2. Append
    try await client.writePrivilegedFile(at: testFile, content: "Line 2\n", append: true)
    #expect(try String(contentsOf: testFile, encoding: .utf8) == "Line 1\nLine 2\n")

    // 3. Overwrite
    try await client.writePrivilegedFile(at: testFile, content: "New Content\n", append: false)
    #expect(try String(contentsOf: testFile, encoding: .utf8) == "New Content\n")
  }

  @Test("createSymlink creates and flips links atomically")
  func createSymlinkOperations() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let client = SudoClient()
    let target1 = tmpDir.appendingPathComponent("target1.txt")
    let target2 = tmpDir.appendingPathComponent("target2.txt")
    let link = tmpDir.appendingPathComponent("link.txt")

    try "T1".write(to: target1, atomically: true, encoding: .utf8)
    try "T2".write(to: target2, atomically: true, encoding: .utf8)

    // Link to target 1
    try await client.createSymlink(from: target1, to: link)
    #expect(try String(contentsOf: link, encoding: .utf8) == "T1")

    // Flip link to target 2
    try await client.createSymlink(from: target2, to: link)
    #expect(try String(contentsOf: link, encoding: .utf8) == "T2")
  }

  @Test("writeFloor writes version to writable directory and overwrites correctly")
  func writeFloorInSandbox() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let env = SystemEnvironment(customRoot: tmpDir)
    let client = SudoClient()

    try await client.writeFloor(repo: "plans-app", version: 1, environment: env)

    let floorFile = env.floorsDirectoryURL.appendingPathComponent("plans-app")
    #expect(FileManager.default.fileExists(atPath: floorFile.path))

    let content1 = try String(contentsOf: floorFile, encoding: .utf8)
    #expect(content1 == "1\n")

    try await client.writeFloor(repo: "plans-app", version: 2, environment: env)

    let content2 = try String(contentsOf: floorFile, encoding: .utf8)
    #expect(content2 == "2\n")
  }

  @Test("installVersion packages version and sets symlinks, uninstall removes them")
  func installVersionAndUninstall() async throws {
    let tmpRoot = FileManager.default.temporaryDirectory.appendingPathComponent("invariants_root_\(UUID().uuidString)")
    let tmpBinDir = FileManager.default.temporaryDirectory.appendingPathComponent("invariants_bin_\(UUID().uuidString)")
    let stageDir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "invariants_stage_\(UUID().uuidString)")

    try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
    try "dummy binary".write(to: stageDir.appendingPathComponent("invariants"), atomically: true, encoding: .utf8)

    let env = SystemEnvironment(customRoot: tmpRoot, customBin: tmpBinDir.appendingPathComponent("invariants"))
    let client = SudoClient()

    defer {
      try? FileManager.default.removeItem(at: tmpRoot)
      try? FileManager.default.removeItem(at: tmpBinDir)
      try? FileManager.default.removeItem(at: stageDir)
    }

    // 1. Install version 1.0.0
    try await client.installVersion(version: "1.0.0", stageDir: stageDir, environment: env)

    let installedBin = env.versionsDirectoryURL.appendingPathComponent("1.0.0/invariants")
    #expect(FileManager.default.fileExists(atPath: installedBin.path))
    #expect(FileManager.default.fileExists(atPath: env.currentVersionURL.path))
    #expect(FileManager.default.fileExists(atPath: env.binURL.path))
    #expect(try String(contentsOf: env.binURL, encoding: .utf8) == "dummy binary")

    // 2. Uninstall (first call)
    try await client.uninstall(environment: env)

    #expect(!FileManager.default.fileExists(atPath: env.rootURL.path))
    #expect(!FileManager.default.fileExists(atPath: env.binURL.path))

    // 3. Uninstall idempotency: calling uninstall again must be a safe, non-throwing no-op
    try await client.uninstall(environment: env)
    #expect(!FileManager.default.fileExists(atPath: env.rootURL.path))
    #expect(!FileManager.default.fileExists(atPath: env.binURL.path))
  }

  @Test("removeItem is strictly idempotent across files, directories, and non-existent paths")
  func removeItemOperations() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let client = SudoClient()
    let file = tmpDir.appendingPathComponent("sample.txt")
    let folder = tmpDir.appendingPathComponent("nested_folder")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try "data".write(to: file, atomically: true, encoding: .utf8)

    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(FileManager.default.fileExists(atPath: folder.path))

    // 1. Remove file + verify idempotency on repeat call
    try await client.removeItem(at: file)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    try await client.removeItem(at: file)
    #expect(!FileManager.default.fileExists(atPath: file.path))

    // 2. Remove directory + verify idempotency on repeat call
    try await client.removeItem(at: folder)
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    try await client.removeItem(at: folder)
    #expect(!FileManager.default.fileExists(atPath: folder.path))

    // 3. Remove non-existent path repeat calls
    let nonExistent = tmpDir.appendingPathComponent("ghost")
    try await client.removeItem(at: nonExistent)
    try await client.removeItem(at: nonExistent)
    #expect(!FileManager.default.fileExists(atPath: nonExistent.path))
  }
}
