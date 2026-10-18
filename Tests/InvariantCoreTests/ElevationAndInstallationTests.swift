import Foundation
import Testing

@testable import InvariantCore

@Suite("Elevation Detection & Installation Management", .tags(.unit))
struct ElevationAndInstallationTests {
  @Test("requiresElevation detects writable user directories without sudo")
  func writableDirectoryRequiresNoElevation() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let testFileURL = tmpDir.appendingPathComponent("floors/test-repo")

    #expect(!SubprocessRunner.requiresElevation(for: testFileURL))
  }

  @Test("requiresElevation detects root-owned directories requiring sudo")
  func rootDirectoryRequiresElevation() {
    let protectedFileURL = SystemPaths.defaultPrefixURL.appendingPathComponent("floors/test-repo")

    #expect(SubprocessRunner.requiresElevation(for: protectedFileURL))
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

    let targetFile = readOnlySubdir.appendingPathComponent("file.txt")

    #expect(SubprocessRunner.requiresElevation(for: targetFile))
  }

  @Test("createSymlink creates and flips links atomically")
  func createSymlinkOperations() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let target1 = tmpDir.appendingPathComponent("target1.txt")
    let target2 = tmpDir.appendingPathComponent("target2.txt")
    let link = tmpDir.appendingPathComponent("link.txt")

    try "T1".write(to: target1, atomically: true, encoding: .utf8)
    try "T2".write(to: target2, atomically: true, encoding: .utf8)

    // Link to target 1
    try await InstallationManager.createSymlink(from: target1, to: link)
    #expect(try String(contentsOf: link, encoding: .utf8) == "T1")

    // Flip link to target 2
    try await InstallationManager.createSymlink(from: target2, to: link)
    #expect(try String(contentsOf: link, encoding: .utf8) == "T2")
  }

  @Test("installVersion packages version and sets symlinks, uninstall removes them")
  func installVersionAndUninstall() async throws {
    let tmpRoot = FileManager.default.temporaryDirectory.appendingPathComponent("invariants_root_\(UUID().uuidString)")
    let tmpBinDir = FileManager.default.temporaryDirectory.appendingPathComponent("invariants_bin_\(UUID().uuidString)")
    let stageDir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "invariants_stage_\(UUID().uuidString)")

    try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
    try "dummy binary".write(to: stageDir.appendingPathComponent("invariants"), atomically: true, encoding: .utf8)

    let env = SystemEnvironment(rootURL: tmpRoot, binURL: tmpBinDir.appendingPathComponent("invariants"))

    defer {
      try? FileManager.default.removeItem(at: tmpRoot)
      try? FileManager.default.removeItem(at: tmpBinDir)
      try? FileManager.default.removeItem(at: stageDir)
    }

    // 1. Install version 1.0.0
    try await InstallationManager.installVersion(version: "1.0.0", stageDir: stageDir, environment: env)

    let installedBin1 = env.versionsDirectoryURL.appendingPathComponent("1.0.0/invariants")
    #expect(FileManager.default.fileExists(atPath: installedBin1.path))
    #expect(FileManager.default.fileExists(atPath: env.currentVersionURL.path))
    #expect(FileManager.default.fileExists(atPath: env.binURL.path))
    #expect(try String(contentsOf: env.binURL, encoding: .utf8) == "dummy binary")

    // 2. Upgrade to version 1.1.0 and verify atomic symlink flip
    let stageDir2 = FileManager.default.temporaryDirectory.appendingPathComponent(
      "invariants_stage2_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: stageDir2, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: stageDir2) }
    try "v1.1.0 binary".write(to: stageDir2.appendingPathComponent("invariants"), atomically: true, encoding: .utf8)

    try await InstallationManager.installVersion(version: "1.1.0", stageDir: stageDir2, environment: env)

    let installedBin2 = env.versionsDirectoryURL.appendingPathComponent("1.1.0/invariants")
    #expect(FileManager.default.fileExists(atPath: installedBin1.path))
    #expect(FileManager.default.fileExists(atPath: installedBin2.path))
    #expect(try String(contentsOf: env.binURL, encoding: .utf8) == "v1.1.0 binary")

    // 3. Uninstall (first call)
    try await InstallationManager.uninstall(environment: env)

    #expect(!FileManager.default.fileExists(atPath: env.rootURL.path))
    #expect(!FileManager.default.fileExists(atPath: env.binURL.path))

    // 4. Uninstall idempotency: calling uninstall again must be a safe, non-throwing no-op
    try await InstallationManager.uninstall(environment: env)
    #expect(!FileManager.default.fileExists(atPath: env.rootURL.path))
    #expect(!FileManager.default.fileExists(atPath: env.binURL.path))
  }

  @Test("runShell executes command with custom environment and working directory")
  func runShellWithParams() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let output = try await SubprocessRunner.runShell(
      "echo $MY_VAR && pwd",
      targetURL: tmpDir,
      workingDirectory: tmpDir,
      environment: ["MY_VAR": "HELLO_PRIVILEGED"]
    )
    #expect(output.exitCode == 0)
    #expect(output.stdoutString.contains("HELLO_PRIVILEGED"))
  }

  @Test("removeItem is strictly idempotent across files, directories, and non-existent paths")
  func removeItemOperations() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let file = tmpDir.appendingPathComponent("sample.txt")
    let folder = tmpDir.appendingPathComponent("nested_folder")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try "data".write(to: file, atomically: true, encoding: .utf8)

    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(FileManager.default.fileExists(atPath: folder.path))

    // 1. Remove file + verify idempotency on repeat call
    try await InstallationManager.removeItem(at: file)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    try await InstallationManager.removeItem(at: file)
    #expect(!FileManager.default.fileExists(atPath: file.path))

    // 2. Remove directory + verify idempotency on repeat call
    try await InstallationManager.removeItem(at: folder)
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    try await InstallationManager.removeItem(at: folder)
    #expect(!FileManager.default.fileExists(atPath: folder.path))

    // 3. Remove non-existent path repeat calls
    let nonExistent = tmpDir.appendingPathComponent("ghost")
    try await InstallationManager.removeItem(at: nonExistent)
    try await InstallationManager.removeItem(at: nonExistent)
    #expect(!FileManager.default.fileExists(atPath: nonExistent.path))
  }

  @Test("SubprocessRunner throws cryptographicError when elevation is required but token is missing")
  func elevationRequiredWithoutTokenThrows() async {
    guard !Authorizer.isRunningAsRoot else { return }

    let protectedURL = SystemPaths.defaultPrefixURL.appendingPathComponent("test-file")
    let request = ProcessRequest(
      binary: .mkdir,
      arguments: ["-p", protectedURL.path],
      targetURL: protectedURL
    )

    await #expect(throws: SystemError.self) {
      try await SubprocessRunner.run(request)
    }
  }

  @Test("SubprocessRunner throws cryptographicError when expired ElevationToken is provided")
  func expiredElevationTokenThrows() async {
    guard !Authorizer.isRunningAsRoot else { return }

    let protectedURL = SystemPaths.defaultPrefixURL.appendingPathComponent("test-file")
    let expiredToken = ElevationToken.forTesting(
      authorizedAt: Date().addingTimeInterval(-400.0),
      expirationInterval: 300.0
    )
    let request = ProcessRequest(
      binary: .mkdir,
      arguments: ["-p", protectedURL.path],
      targetURL: protectedURL,
      elevationToken: expiredToken
    )

    await #expect(throws: SystemError.self) {
      try await SubprocessRunner.run(request)
    }
  }

  @Test("SubprocessRunner executes SystemBinary commands directly")
  func systemBinaryDirectExecution() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let targetDir = tmpDir.appendingPathComponent("subfolder")
    let output = try await SubprocessRunner.run(
      binary: .mkdir,
      arguments: ["-p", targetDir.path],
      targetURL: targetDir,
      checkExitCode: true
    )
    #expect(output.exitCode == 0)
    #expect(FileManager.default.fileExists(atPath: targetDir.path))
  }

  @Test("InstallationManager operations accept optional ElevationToken seamlessly")
  func installationManagerWithToken() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let token = ElevationToken.forTesting()
    let file = tmpDir.appendingPathComponent("token_test.txt")
    try "hello".write(to: file, atomically: true, encoding: .utf8)

    try await InstallationManager.removeItem(at: file, token: token)
    #expect(!FileManager.default.fileExists(atPath: file.path))
  }
}
