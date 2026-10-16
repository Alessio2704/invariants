import Foundation
import Testing

@testable import InvariantCore

@Suite("Rollback & Floor Protection", .tags(.unit))
struct FloorTests {
  @Test("Git history ancestry check refuses versions lower than recorded commit history")
  func historyFloorCheck() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fm = FileManager.default
    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    let runner = SubprocessRunner()
    _ = try await runner.run(
      executableURL: SubprocessRunner.gitURL, arguments: ["-C", tmpDir.path, "init", "-b", "main"])
    _ = try await runner.run(
      executableURL: SubprocessRunner.gitURL, arguments: ["-C", tmpDir.path, "config", "user.name", "Tester"])
    _ = try await runner.run(
      executableURL: SubprocessRunner.gitURL,
      arguments: ["-C", tmpDir.path, "config", "user.email", "test@invariants.local"]
    )

    let invDir = tmpDir.appendingPathComponent("invariants")
    try fm.createDirectory(at: invDir, withIntermediateDirectories: true)
    let lockFile = invDir.appendingPathComponent("registry.lock")
    let gitClient = GitClient()
    let guardObj = FloorGuard(gitClient: gitClient)

    // Commit v1
    let reg1 = Registry(version: 1, engine: "^1.0.0")
    try CanonicalJSON.serialize(reg1).data(using: .utf8)?.write(to: lockFile)
    try await gitClient.commit(repoRoot: tmpDir, paths: ["invariants/registry.lock"], message: "v1")

    // Commit v2
    let reg2 = Registry(version: 2, engine: "^1.0.0")
    try CanonicalJSON.serialize(reg2).data(using: .utf8)?.write(to: lockFile)
    try await gitClient.commit(repoRoot: tmpDir, paths: ["invariants/registry.lock"], message: "v2")

    // Current version 2 is valid
    let maxV = try await guardObj.checkHistory(repoRoot: tmpDir, currentVersion: 2)
    #expect(maxV == 2)

    // Attempting to evaluate with version 1 must throw versionBelowHistory
    await #expect(throws: FloorError.versionBelowHistory(current: 1, maxHistoryVersion: 2)) {
      _ = try await guardObj.checkHistory(repoRoot: tmpDir, currentVersion: 1)
    }
  }

  @Test("No-rewrite guard rejects deletion and force-push of default branch")
  func noRewriteGuard() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fm = FileManager.default
    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    let runner = SubprocessRunner()
    _ = try await runner.run(
      executableURL: SubprocessRunner.gitURL, arguments: ["-C", tmpDir.path, "init", "-b", "main"])

    let dummyFile = tmpDir.appendingPathComponent("file.txt")
    try Data("hello".utf8).write(to: dummyFile)
    let gitClient = GitClient()
    try await gitClient.commit(repoRoot: tmpDir, paths: ["file.txt"], message: "init")

    let guardObj = FloorGuard(gitClient: gitClient)

    // 1. Branch deletion simulation
    let deleteStdin =
      "refs/heads/main 0000000000000000000000000000000000000000 refs/heads/main 1111111111111111111111111111111111111111\n"
    await #expect(throws: FloorError.branchDeletion(branch: "main")) {
      try await guardObj.checkNoRewrite(repoRoot: tmpDir, pushedRefsInput: deleteStdin, defaultBranch: "main")
    }

    // 2. Non-fast-forward push simulation
    let nonFfStdin =
      "refs/heads/main 1111111111111111111111111111111111111111 refs/heads/main 2222222222222222222222222222222222222222\n"
    await #expect(throws: FloorError.self) {
      try await guardObj.checkNoRewrite(repoRoot: tmpDir, pushedRefsInput: nonFfStdin, defaultBranch: "main")
    }

    // 3. Custom default branch (e.g. trunk) protection
    let trunkDeleteStdin =
      "refs/heads/trunk 0000000000000000000000000000000000000000 refs/heads/trunk 1111111111111111111111111111111111111111\n"
    await #expect(throws: FloorError.branchDeletion(branch: "trunk")) {
      try await guardObj.checkNoRewrite(repoRoot: tmpDir, pushedRefsInput: trunkDeleteStdin, defaultBranch: "trunk")
    }

    // 4. Feature branch push is permitted even with non-zero refs
    let featureStdin =
      "refs/heads/feat 1111111111111111111111111111111111111111 refs/heads/feat 0000000000000000000000000000000000000000\n"
    // Pushing to feature branch must not throw for protected branch "main"
    try await guardObj.checkNoRewrite(repoRoot: tmpDir, pushedRefsInput: featureStdin, defaultBranch: "main")
  }
}
