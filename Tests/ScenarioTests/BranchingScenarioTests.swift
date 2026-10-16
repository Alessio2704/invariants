import Foundation
import Testing

@testable import InvariantCore

@Suite("Branching & Trunk Lifecycle Scenarios", .tags(.scenario))
struct BranchingScenarioTests {

  @Test("Scenario 1: Invariants initialized on main, branched out to add rules, and merged back")
  func scenario1_initOnMainAndBranchMerge() async throws {
    let repo = try await TestRepo()
    let sshClient = SSHKeygenClient()
    let gitClient = GitClient()
    let runner = SubprocessRunner()
    let manager = RegistryManager(environment: repo.environment, sshClient: sshClient)

    // 1. Initialized on main
    let reg1 = Registry(version: 1, engine: "^1.0.0", defaultBranch: "main")
    try await manager.saveAndSign(registry: reg1, repoRoot: repo.repoURL, keyURL: repo.keyURL)
    try await gitClient.commit(repoRoot: repo.repoURL, paths: ["."], message: "Init invariants on main")

    // 2. Branch out to feat/new-rule
    _ = try await runner.run(
      executableURL: SubprocessRunner.gitURL,
      arguments: ["-C", repo.repoURL.path, "checkout", "-b", "feat/new-rule"]
    )

    // 3. Add rule and bump to v2
    try repo.withRule("branch-rule")
    var reg2 = reg1
    reg2.version = 2
    reg2.rules["branch-rule"] = "hash-branch"
    try await manager.saveAndSign(registry: reg2, repoRoot: repo.repoURL, keyURL: repo.keyURL)
    try await gitClient.commit(repoRoot: repo.repoURL, paths: ["."], message: "Add branch-rule on feature branch")

    // Feature branch can push freely (not blocked by trunk rewrite guard)
    let floorGuard = FloorGuard()
    let pushInput = "refs/heads/feat/new-rule 1111 refs/heads/feat/new-rule 2222\n"
    try await floorGuard.checkNoRewrite(
      repoRoot: repo.repoURL, pushedRefsInput: pushInput, defaultBranch: reg2.defaultBranch)

    // 4. Merge back into main
    _ = try await runner.run(
      executableURL: SubprocessRunner.gitURL,
      arguments: ["-C", repo.repoURL.path, "checkout", "main"]
    )
    _ = try await runner.run(
      executableURL: SubprocessRunner.gitURL,
      arguments: ["-C", repo.repoURL.path, "merge", "--no-ff", "feat/new-rule", "-m", "Merge feat/new-rule into main"]
    )

    // On main: registry is v2, trunk is main, ancestry checks pass
    let regOnMain = try await manager.loadAndVerify(repoRoot: repo.repoURL)
    #expect(regOnMain.version == 2)
    #expect(regOnMain.defaultBranch == "main")
    #expect(regOnMain.rules["branch-rule"] != nil)

    let histFloor = try await floorGuard.checkHistory(repoRoot: repo.repoURL, currentVersion: regOnMain.version)
    #expect(histFloor == 2)
  }

  @Test("Scenario 2: Invariants initialized on feature branch, merged back into main")
  func scenario2_initOnFeatureBranchAndMerge() async throws {
    let repo = try await TestRepo()
    let runner = SubprocessRunner()
    let gitClient = GitClient()
    let sshClient = SSHKeygenClient()
    let registryManager = RegistryManager(environment: repo.environment, sshClient: sshClient)

    // 1. Initial commit on main so main exists
    let dummyFile = repo.repoURL.appendingPathComponent("README.md")
    try "# Project\n".write(to: dummyFile, atomically: true, encoding: .utf8)
    try await gitClient.commit(repoRoot: repo.repoURL, paths: ["README.md"], message: "Initial commit on main")

    // 2. Checkout feature branch BEFORE initializing invariants
    _ = try await runner.run(
      executableURL: SubprocessRunner.gitURL,
      arguments: ["-C", repo.repoURL.path, "checkout", "-b", "feat/setup-invariants"]
    )

    // 3. Initialize invariants using automatic default branch detection (as InitCommand does)
    let detectedBranch = await gitClient.detectDefaultBranch(repoRoot: repo.repoURL)
    let initManager = InitManager(registryManager: registryManager, gitClient: gitClient)
    let options = InitOptions(
      engineVersion: "1.0.0",
      defaultBranch: detectedBranch,
      keyURL: repo.keyURL
    )
    try await initManager.initialize(repoRootURL: repo.repoURL, options: options)

    // 4. Merge feature branch into main
    _ = try await runner.run(
      executableURL: SubprocessRunner.gitURL,
      arguments: ["-C", repo.repoURL.path, "checkout", "main"]
    )
    _ = try await runner.run(
      executableURL: SubprocessRunner.gitURL,
      arguments: [
        "-C", repo.repoURL.path, "merge", "--no-ff", "feat/setup-invariants", "-m", "Merge feat/setup-invariants",
      ]
    )

    // 5. Verify registry on main
    let regOnMain = try await registryManager.loadAndVerify(repoRoot: repo.repoURL)

    // CRITICAL ASSERTION: The repository trunk must be 'main', NOT 'feat/setup-invariants'
    #expect(regOnMain.defaultBranch == "main")

    // 6. Delete the merged feature branch and verify FloorGuard does NOT block deletion
    let floorGuard = FloorGuard()
    let deletePush =
      "(delete) 0000000000000000000000000000000000000000 refs/heads/feat/setup-invariants 1111111111111111111111111111111111111111\n"
    try await floorGuard.checkNoRewrite(
      repoRoot: repo.repoURL,
      pushedRefsInput: deletePush,
      defaultBranch: regOnMain.defaultBranch
    )
  }
}
