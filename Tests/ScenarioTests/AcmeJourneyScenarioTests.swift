import Foundation
import Testing

@testable import Core
@testable import Workflows

@Suite("Acme Journey - Full Lifecycle Orchestrator", .tags(.scenario), .tags(.integration))
struct AcmeFullJourneyTests {
  @Test("Acme Company Full Lifecycle: Day 0 to Month 12 Continuous Journey")
  func acmeFullJourney() async throws {
    let ctx = try await AcmeJourneyContext()

    for milestone in AcmeMilestone.allCases {
      try await AcmeJourneyContext.execute(milestone: milestone, ctx: ctx)
    }
  }
}

@Suite("Acme Journey - Isolated Milestone Tests", .serialized, .tags(.scenario))
struct AcmeIsolatedMilestoneTests {
  @Test("Milestone: Day 0 Init Repository (v1)")
  func milestone_v01_init() async throws {
    let ctx = try await AcmeJourneyContext.bootstrap(upTo: .v01_init)
    try await AcmeSteps.step_v01_day0_initRepository(ctx: ctx)
  }

  @Test("Milestone: Day 1 Add Swift Rule (v2)")
  func milestone_v02_addSwiftRule() async throws {
    let ctx = try await AcmeJourneyContext.bootstrap(upTo: .v02_addSwiftRule)
    try await AcmeSteps.step_v02_day1_addSwiftRule(ctx: ctx)
  }

  @Test("Milestone: Week 2 Repel Agent Attacks")
  func milestone_interlude_agentAttacks() async throws {
    let ctx = try await AcmeJourneyContext.bootstrap(upTo: .interlude_week2_agentAttacks)
    try await AcmeSteps.step_interlude_week2_agentAttacks(ctx: ctx)
  }

  @Test("Milestone: Week 3 Enroll Bob (v3)")
  func milestone_v03_enrollBob() async throws {
    let ctx = try await AcmeJourneyContext.bootstrap(upTo: .v03_enrollBob)
    try await AcmeSteps.step_v03_week3_enrollBob(ctx: ctx)
  }

  @Test("Milestone: Month 2 Configure TypeScript (v4)")
  func milestone_v04_configTS() async throws {
    let ctx = try await AcmeJourneyContext.bootstrap(upTo: .v04_configTS)
    try await AcmeSteps.step_v04_month2_configTypeScript(ctx: ctx)
  }

  @Test("Milestone: Month 2 Enroll Carol (v5)")
  func milestone_v05_enrollCarol() async throws {
    let ctx = try await AcmeJourneyContext.bootstrap(upTo: .v05_enrollCarol)
    try await AcmeSteps.step_v05_month2_enrollCarol(ctx: ctx)
  }

  @Test("Milestone: Month 2 Add TypeScript Rule (v6)")
  func milestone_v06_addTSRule() async throws {
    let ctx = try await AcmeJourneyContext.bootstrap(upTo: .v06_addTSRule)
    try await AcmeSteps.step_v06_month2_addTypeScriptRule(ctx: ctx)
  }

  @Test("Milestone: Month 3 Enroll Dave (v7)")
  func milestone_v07_enrollDave() async throws {
    let ctx = try await AcmeJourneyContext.bootstrap(upTo: .v07_enrollDave)
    try await AcmeSteps.step_v07_month3_enrollDave(ctx: ctx)
  }

  @Test("Milestone: Month 3 Strengthen Swift Rule (v8)")
  func milestone_v08_strengthenSwiftRule() async throws {
    let ctx = try await AcmeJourneyContext.bootstrap(upTo: .v08_strengthenSwiftRule)
    try await AcmeSteps.step_v08_month3_strengthenSwiftRule(ctx: ctx)
  }

  @Test("Milestone: Month 3 Block Rule Weakening")
  func milestone_interlude_weakeningBlocked() async throws {
    let ctx = try await AcmeJourneyContext.bootstrap(upTo: .interlude_month3_weakeningBlocked)
    try await AcmeSteps.step_interlude_month3_weakeningBlocked(ctx: ctx)
  }

  @Test("Milestone: Month 4 Rotate Bob Key with Sunset (v9)")
  func milestone_v09_rotateBobKey() async throws {
    let ctx = try await AcmeJourneyContext.bootstrap(upTo: .v09_rotateBobKeyWithSunset)
    try await AcmeSteps.step_v09_month4_rotateBobKeyWithSunset(ctx: ctx)
  }

  @Test("Milestone: Month 4 Re-seal with Bob New Key (v10)")
  func milestone_v10_reSealBobNewKey() async throws {
    let ctx = try await AcmeJourneyContext.bootstrap(upTo: .v10_reSealBobKeyNew)
    try await AcmeSteps.step_v10_month4_reSealWithBobNewKey(ctx: ctx)
  }

  @Test("Milestone: Month 6 Soft Revoke Dave (v11)")
  func milestone_v11_revokeDaveSoft() async throws {
    let ctx = try await AcmeJourneyContext.bootstrap(upTo: .v11_revokeDaveSoft)
    try await AcmeSteps.step_v11_month6_revokeDaveSoft(ctx: ctx)
  }

  @Test("Milestone: Month 7 Hard Revoke Bob Old Key (v12)")
  func milestone_v12_hardRevokeBobOld() async throws {
    let ctx = try await AcmeJourneyContext.bootstrap(upTo: .v12_hardRevokeBobOld)
    try await AcmeSteps.step_v12_month7_incidentHardRevokeBobOld(ctx: ctx)
  }

  @Test("Milestone: Month 8 Upgrade Engine Registry (v13)")
  func milestone_v13_upgradeEngine() async throws {
    let ctx = try await AcmeJourneyContext.bootstrap(upTo: .v13_upgradeEngine)
    try await AcmeSteps.step_v13_month8_upgradeEngine(ctx: ctx)
  }

  @Test("Milestone: Month 12 Mature Repository Audit")
  func milestone_audit_month12_matureRepository() async throws {
    let ctx = try await AcmeJourneyContext.bootstrap(upTo: .audit_month12_matureRepository)
    try await AcmeSteps.step_audit_month12_matureRepository(ctx: ctx)
  }
}
