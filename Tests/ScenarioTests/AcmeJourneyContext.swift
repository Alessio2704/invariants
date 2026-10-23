import Foundation
import Testing

@testable import Core
@testable import Workflows

/// Milestones corresponding to each state mutation and adversarial interlude in the Acme lifecycle.
enum AcmeMilestone: String, CaseIterable, Sendable {
  case v01_init = "Day 0: Init Repository"
  case v02_addSwiftRule = "Day 1: Add Swift Rule"
  case interlude_week2_agentAttacks = "Week 2: Repel Agent Attacks"
  case v03_enrollBob = "Week 3: Enroll Bob"
  case v04_configTS = "Month 2: Configure TypeScript"
  case v05_enrollCarol = "Month 2: Enroll Carol"
  case v06_addTSRule = "Month 2: Add TypeScript Rule"
  case v07_enrollDave = "Month 3: Enroll Dave (Contractor)"
  case v08_strengthenSwiftRule = "Month 3: Strengthen Swift Rule"
  case interlude_month3_weakeningBlocked = "Month 3: Block Rule Weakening"
  case v09_rotateBobKeyWithSunset = "Month 4: Rotate Bob Key with Sunset"
  case v10_reSealBobKeyNew = "Month 4: Re-seal with Bob New Key"
  case v11_revokeDaveSoft = "Month 6: Soft Revoke Dave"
  case v12_hardRevokeBobOld = "Month 7: Hard Revoke Bob Old Key"
  case v13_upgradeEngine = "Month 8: Upgrade Engine Registry"
  case audit_month12_matureRepository = "Month 12: Mature Repository Audit"
}

/// Simulated Acme company workspace and team key store.
final class AcmeJourneyContext: @unchecked Sendable {
  let baseDir: URL
  let repoURL: URL
  let keysDir: URL

  // Team signing keys
  let aliceKey: URL
  let bobKey: URL
  let bobNewKey: URL
  let carolKey: URL
  let daveKey: URL
  let rogueAgentKey: URL

  // Cached public keys
  let alicePub: String
  let bobPub: String
  let bobNewPub: String
  let carolPub: String
  let davePub: String
  let rogueAgentPub: String

  init() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("acme_journey_\(UUID().uuidString)")
    self.baseDir = base
    self.repoURL = base.appendingPathComponent("acme-app")
    self.keysDir = base.appendingPathComponent("keys")

    try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
    try fm.createDirectory(at: keysDir, withIntermediateDirectories: true)

    self.aliceKey = keysDir.appendingPathComponent("alice_p256")
    self.bobKey = keysDir.appendingPathComponent("bob_p256")
    self.bobNewKey = keysDir.appendingPathComponent("bob_new_p256")
    self.carolKey = keysDir.appendingPathComponent("carol_p256")
    self.daveKey = keysDir.appendingPathComponent("dave_p256")
    self.rogueAgentKey = keysDir.appendingPathComponent("agent_p256")

    try SigningClient.generateThrowawayKey(at: aliceKey)
    try SigningClient.generateThrowawayKey(at: bobKey)
    try SigningClient.generateThrowawayKey(at: bobNewKey)
    try SigningClient.generateThrowawayKey(at: carolKey)
    try SigningClient.generateThrowawayKey(at: daveKey)
    try SigningClient.generateThrowawayKey(at: rogueAgentKey)

    self.alicePub = try keysDir.appendingPathComponent("alice_p256.pub").readTrimmedUTF8()
    self.bobPub = try keysDir.appendingPathComponent("bob_p256.pub").readTrimmedUTF8()
    self.bobNewPub = try keysDir.appendingPathComponent("bob_new_p256.pub").readTrimmedUTF8()
    self.carolPub = try keysDir.appendingPathComponent("carol_p256.pub").readTrimmedUTF8()
    self.davePub = try keysDir.appendingPathComponent("dave_p256.pub").readTrimmedUTF8()
    self.rogueAgentPub = try keysDir.appendingPathComponent("agent_p256.pub").readTrimmedUTF8()

    _ = try await SubprocessRunner.run(
      binary: .git, arguments: ["-C", repoURL.path, "init", "-b", "main"])
    _ = try await SubprocessRunner.run(
      binary: .git, arguments: ["-C", repoURL.path, "config", "user.name", "Alice TechLead"])
    _ = try await SubprocessRunner.run(
      binary: .git, arguments: ["-C", repoURL.path, "config", "user.email", "alice@acme.com"])

    let packageSwift = """
      // swift-tools-version: 6.0
      import PackageDescription
      let package = Package(
          name: "AcmeApp",
          products: [.library(name: "AcmeCore", targets: ["AcmeCore"])],
          targets: [.target(name: "AcmeCore")]
      )
      """
    try packageSwift.write(
      to: repoURL.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

    let acmeCore = repoURL.appendingPathComponent("Sources/AcmeCore/App.swift")
    try fm.createDirectory(at: acmeCore.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "public struct AcmeApp { public init() {} }\n".write(
      to: acmeCore, atomically: true, encoding: .utf8)

    let outStore = repoURL.appendingPathComponent(".build/out")
    try fm.createDirectory(at: outStore, withIntermediateDirectories: true)

    _ = try await SubprocessRunner.run(binary: .git, arguments: ["-C", repoURL.path, "add", "."])
    _ = try await SubprocessRunner.run(
      binary: .git, arguments: ["-C", repoURL.path, "commit", "-m", "Initial commit of acme-app"])
  }

  deinit {
    try? FileManager.default.removeItem(at: baseDir)
  }

  func run<T>(_ operation: () async throws -> T) async rethrows -> T {
    try await RepoLocator.withRepoRoot(repoURL, operation: operation)
  }

  static func bootstrap(upTo target: AcmeMilestone) async throws -> AcmeJourneyContext {
    let ctx = try await AcmeJourneyContext()
    for milestone in AcmeMilestone.allCases {
      if milestone == target { break }
      try await execute(milestone: milestone, ctx: ctx)
    }
    return ctx
  }

  static func execute(milestone: AcmeMilestone, ctx: AcmeJourneyContext) async throws {
    switch milestone {
    case .v01_init:
      try await AcmeSteps.step_v01_day0_initRepository(ctx: ctx)
    case .v02_addSwiftRule:
      try await AcmeSteps.step_v02_day1_addSwiftRule(ctx: ctx)
    case .interlude_week2_agentAttacks:
      try await AcmeSteps.step_interlude_week2_agentAttacks(ctx: ctx)
    case .v03_enrollBob:
      try await AcmeSteps.step_v03_week3_enrollBob(ctx: ctx)
    case .v04_configTS:
      try await AcmeSteps.step_v04_month2_configTypeScript(ctx: ctx)
    case .v05_enrollCarol:
      try await AcmeSteps.step_v05_month2_enrollCarol(ctx: ctx)
    case .v06_addTSRule:
      try await AcmeSteps.step_v06_month2_addTypeScriptRule(ctx: ctx)
    case .v07_enrollDave:
      try await AcmeSteps.step_v07_month3_enrollDave(ctx: ctx)
    case .v08_strengthenSwiftRule:
      try await AcmeSteps.step_v08_month3_strengthenSwiftRule(ctx: ctx)
    case .interlude_month3_weakeningBlocked:
      try await AcmeSteps.step_interlude_month3_weakeningBlocked(ctx: ctx)
    case .v09_rotateBobKeyWithSunset:
      try await AcmeSteps.step_v09_month4_rotateBobKeyWithSunset(ctx: ctx)
    case .v10_reSealBobKeyNew:
      try await AcmeSteps.step_v10_month4_reSealWithBobNewKey(ctx: ctx)
    case .v11_revokeDaveSoft:
      try await AcmeSteps.step_v11_month6_revokeDaveSoft(ctx: ctx)
    case .v12_hardRevokeBobOld:
      try await AcmeSteps.step_v12_month7_incidentHardRevokeBobOld(ctx: ctx)
    case .v13_upgradeEngine:
      try await AcmeSteps.step_v13_month8_upgradeEngine(ctx: ctx)
    case .audit_month12_matureRepository:
      try await AcmeSteps.step_audit_month12_matureRepository(ctx: ctx)
    }
  }
}
