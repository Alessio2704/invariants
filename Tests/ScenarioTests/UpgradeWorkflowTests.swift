import Foundation
import Testing

@testable import Core
@testable import Workflows

@Suite("Upgrade Registry & Semver Migration Regression Tests", .tags(.scenario))
struct UpgradeWorkflowTests {

  @Test("RegistryManager.loadAndVerify allows engine mismatch when allowEngineMismatch is true")
  func testLoadAndVerifyWithEngineMismatchAllowed() async throws {
    let repo = try await TestRepo()
    try repo.withRule("test-semver-rule")
    // Version 1 requires engine "^1.0.0"
    try await repo.signed(version: 1, defaultBranch: "main")

    // Attempting to load registry with installed engine "2.0.0" without allowEngineMismatch must throw
    await #expect(throws: RegistryError.self) {
      try await repo.run {
        _ = try await RegistryManager.loadAndVerify(
          installedEngineVersion: "2.0.0",
          identity: "*",
          allowEngineMismatch: false
        )
      }
    }

    // Attempting to load registry with installed engine "2.0.0" WITH allowEngineMismatch must succeed
    let registry = try await repo.run {
      try await RegistryManager.loadAndVerify(
        installedEngineVersion: "2.0.0",
        identity: "*",
        allowEngineMismatch: true
      )
    }
    #expect(registry.version == 1)
    #expect(registry.engine == "^1.0.0")
  }
}
