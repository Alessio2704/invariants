import Foundation
import Testing

@testable import InvariantCore

@Suite("Rollback & Floor Protection", .tags(.unit))
struct FloorTests {
  @Test("Root floor check refuses versions lower than recorded floor")
  func rootFloorCheck() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fm = FileManager.default
    let floorsDir = tmpDir.appendingPathComponent("floors")
    try fm.createDirectory(at: floorsDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    let env = SystemEnvironment(customRoot: tmpDir)
    let floorFile = floorsDir.appendingPathComponent("sample-repo")
    try Data("5\n".utf8).write(to: floorFile)

    let guardObj = FloorGuard()

    // Version 5 is allowed
    let v5 = try guardObj.checkRootFloor(repo: "sample-repo", currentVersion: 5, environment: env)
    #expect(v5 == 5)

    // Version 6 is allowed
    let v6 = try guardObj.checkRootFloor(repo: "sample-repo", currentVersion: 6, environment: env)
    #expect(v6 == 5)

    // Version 4 is below floor 5 -> must throw versionBelowRootFloor
    #expect(throws: FloorError.versionBelowRootFloor(current: 4, rootFloor: 5, repo: "sample-repo")) {
      _ = try guardObj.checkRootFloor(repo: "sample-repo", currentVersion: 4, environment: env)
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
  }
}
