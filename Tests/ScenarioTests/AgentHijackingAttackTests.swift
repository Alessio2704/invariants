import Foundation
import Testing

@testable import Core

@Suite("Autonomous Agent Hijacking & Trunk Protection Attacks", .tags(.scenario), .tags(.security))
struct AgentHijackingAttackTests {

  @Test("Attack 1: Agent modifies default_branch in registry.lock without human signature")
  func attack1_tamperDefaultBranchWithoutSignature() async throws {
    let repo = try await TestRepo()
    try repo.withRule("attack-rule-1")
    try await repo.signed(version: 1, defaultBranch: "main")

    let lockURL = RegistryManager.registryURL(repoRoot: repo.repoURL)
    let originalContent = try String(contentsOf: lockURL, encoding: .utf8)
    #expect(originalContent.contains("\"default_branch\": \"main\""))

    // Agent attempts to change default_branch from "main" to "rogue-branch" to divert protection
    let tamperedContent = originalContent.replacingOccurrences(
      of: "\"default_branch\": \"main\"",
      with: "\"default_branch\": \"rogue-branch\""
    )
    try tamperedContent.write(to: lockURL, atomically: true, encoding: .utf8)

    // Verification must fail with signatureInvalid because the signature was computed on "main"
    await #expect(throws: RegistryError.self) {
      _ = try await RegistryManager.loadAndVerify(repoRoot: repo.repoURL)
    }
  }

  @Test("Attack 2: Agent self-generates key to sign a modified default_branch, rejected by Ancestry Authority")
  func attack2_selfAuthorizedKeyCannotChangeDefaultBranch() async throws {
    let repo = try await TestRepo()
    try repo.withRule("attack-rule-2")
    try await repo.signed(version: 1, defaultBranch: "main")

    // Agent generates throwaway key
    let rogueKeyURL = repo.repoURL.appendingPathComponent("id_rogue_agent")
    try SigningClient.generateThrowawayKey(at: rogueKeyURL)
    let roguePub = try String(contentsOf: repo.repoURL.appendingPathComponent("id_rogue_agent.pub"), encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    // Agent appends its key to allowed_signers
    let signersURL = RegistryManager.allowedSignersURL(repoRoot: repo.repoURL)
    var signers = try String(contentsOf: signersURL, encoding: .utf8)
    signers.append("* namespaces=\"invariants\" \(roguePub)\n")
    try signers.write(to: signersURL, atomically: true, encoding: .utf8)

    // Agent attempts to retarget default_branch to "unprotected" in version 2
    let reg2 = Registry.forTesting(
      version: 2,
      engine: "^1.0.0",
      defaultBranch: "unprotected"
    )
    try await RegistryManager.saveAndSign(registry: reg2, repoRoot: repo.repoURL, keyURL: rogueKeyURL)

    // FloorGuard ancestry check must reject because rogue key was not authorized in parent commit v1!
    let lockURL = RegistryManager.registryURL(repoRoot: repo.repoURL)
    let sigURL = RegistryManager.signatureURL(repoRoot: repo.repoURL)

    await #expect(throws: FloorError.self) {
      try await FloorGuard.checkSignerAncestry(
        repoRoot: repo.repoURL,
        currentRegistry: reg2,
        lockURL: lockURL,
        sigURL: sigURL
      )
    }
  }

  @Test("Attack 3: Agent attempts force-push non-fast-forward rewrite on signed trunk branch")
  func attack3_forcePushOverSignedTrunkBranchRejected() async throws {
    let repo = try await TestRepo()
    try repo.withRule("attack-rule-3")
    try await repo.signed(version: 1, defaultBranch: "main")

    let reg = try await RegistryManager.loadAndVerify(repoRoot: repo.repoURL)
    #expect(reg.defaultBranch == "main")

    // Simulate git pre-push hook input with non-fast-forward commits on default_branch
    let nonFastForwardStdin =
      "refs/heads/main 1111111111111111111111111111111111111111 refs/heads/main 2222222222222222222222222222222222222222\n"

    await #expect(throws: FloorError.nonFastForwardPush(branch: "main")) {
      try await FloorGuard.checkNoRewrite(
        repoRoot: repo.repoURL,
        pushedRefsInput: nonFastForwardStdin,
        defaultBranch: reg.defaultBranch
      )
    }
  }

  @Test("Attack 4: Agent attempts force-push on custom signed trunk branch (e.g. develop)")
  func attack4_forcePushOverCustomTrunkBranchRejected() async throws {
    let repo = try await TestRepo()
    try repo.withRule("attack-rule-4")
    try await repo.signed(version: 1, defaultBranch: "develop")

    let reg = try await RegistryManager.loadAndVerify(repoRoot: repo.repoURL)
    #expect(reg.defaultBranch == "develop")

    // Force-push to "develop" must be rejected
    let nonFastForwardStdin =
      "refs/heads/develop 1111111111111111111111111111111111111111 refs/heads/develop 2222222222222222222222222222222222222222\n"

    await #expect(throws: FloorError.nonFastForwardPush(branch: "develop")) {
      try await FloorGuard.checkNoRewrite(
        repoRoot: repo.repoURL,
        pushedRefsInput: nonFastForwardStdin,
        defaultBranch: reg.defaultBranch
      )
    }
  }

  @Test("Attack 5: Agent attempts to sneak a force-push inside a batched multi-branch push")
  func attack5_batchedPushForcePushDetectedAndBlocked() async throws {
    let repo = try await TestRepo()
    try repo.withRule("attack-rule-5")
    try await repo.signed(version: 1, defaultBranch: "main")

    // Multi-line push input: first line is a legitimate feature branch, second line sneaks a force-push to main
    let batchedStdin = """
      refs/heads/feat/cleanup aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111 refs/heads/feat/cleanup 0000000000000000000000000000000000000000
      refs/heads/main 1111111111111111111111111111111111111111 refs/heads/main 2222222222222222222222222222222222222222
      """

    await #expect(throws: FloorError.nonFastForwardPush(branch: "main")) {
      try await FloorGuard.checkNoRewrite(
        repoRoot: repo.repoURL,
        pushedRefsInput: batchedStdin,
        defaultBranch: "main"
      )
    }
  }

  @Test("Attack 6: Agent attempts trunk branch deletion (git push origin :main)")
  func attack6_trunkDeletionBlocked() async throws {
    let repo = try await TestRepo()
    try repo.withRule("attack-rule-6")
    try await repo.signed(version: 1, defaultBranch: "main")

    // Zero SHA indicates branch deletion in git pre-push
    let deleteStdin =
      "refs/heads/main 0000000000000000000000000000000000000000 refs/heads/main 1111111111111111111111111111111111111111\n"

    await #expect(throws: FloorError.branchDeletion(branch: "main")) {
      try await FloorGuard.checkNoRewrite(
        repoRoot: repo.repoURL,
        pushedRefsInput: deleteStdin,
        defaultBranch: "main"
      )
    }

    // Literal "(delete)" marker also caught
    let literalDeleteStdin =
      "(delete) 0000000000000000000000000000000000000000 refs/heads/main 1111111111111111111111111111111111111111\n"
    await #expect(throws: FloorError.branchDeletion(branch: "main")) {
      try await FloorGuard.checkNoRewrite(
        repoRoot: repo.repoURL,
        pushedRefsInput: literalDeleteStdin,
        defaultBranch: "main"
      )
    }
  }

  @Test("Attack 7: Agent pushes to an arbitrary feature branch without interference")
  func attack7_featureBranchPushesAllowed() async throws {
    let repo = try await TestRepo()
    try repo.withRule("attack-rule-7")
    try await repo.signed(version: 1, defaultBranch: "main")

    // Pushing a brand new feature branch (remote sha = 0)
    let newBranchStdin =
      "refs/heads/feat/experiment 1111111111111111111111111111111111111111 "
      + "refs/heads/feat/experiment 0000000000000000000000000000000000000000\n"

    // Must succeed without throwing
    try await FloorGuard.checkNoRewrite(
      repoRoot: repo.repoURL,
      pushedRefsInput: newBranchStdin,
      defaultBranch: "main"
    )
  }

  @Test("Attack 8: Agent removes default_branch field completely from registry.lock")
  func attack8_omittingDefaultBranchBreaksSignatureAndDefaultsToMain() async throws {
    let repo = try await TestRepo()
    try repo.withRule("attack-rule-8")
    try await repo.signed(version: 1, defaultBranch: "custom")

    let lockURL = RegistryManager.registryURL(repoRoot: repo.repoURL)
    let original = try String(contentsOf: lockURL, encoding: .utf8)

    // Agent deletes the default_branch line
    let lines = original.split(separator: "\n").filter { !$0.contains("default_branch") }.joined(separator: "\n") + "\n"
    try lines.write(to: lockURL, atomically: true, encoding: .utf8)

    // 1. Signature check fails immediately
    await #expect(throws: RegistryError.self) {
      _ = try await RegistryManager.loadAndVerify(repoRoot: repo.repoURL)
    }

    // 2. Direct parsing (simulating a legacy lockfile) falls back safely to "main" rather than nil/empty
    let lockData = try Data(contentsOf: lockURL)
    let fallbackRegistry = try CanonicalJSON.parse(data: lockData)
    #expect(fallbackRegistry.defaultBranch == "main")
  }
}
