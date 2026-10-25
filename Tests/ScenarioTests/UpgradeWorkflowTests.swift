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
    // Version 1 requires incompatible engine "^99.0.0"
    try await repo.signed(version: 1, engine: "^99.0.0", defaultBranch: "main")

    // Attempting to load registry without allowEngineMismatch must throw
    await #expect(throws: RegistryError.engineVersionMismatch(required: "^99.0.0", installed: EngineVersion.current)) {
      try await repo.run {
        _ = try await RegistryManager.loadAndVerify(
          identity: "*",
          allowEngineMismatch: false
        )
      }
    }

    // Attempting to load registry WITH allowEngineMismatch must succeed
    let registry = try await repo.run {
      try await RegistryManager.loadAndVerify(
        identity: "*",
        allowEngineMismatch: true
      )
    }
    #expect(registry.version == 1)
    #expect(registry.engine == "^99.0.0")
  }
}
