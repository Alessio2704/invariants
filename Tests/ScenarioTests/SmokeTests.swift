import Testing

@testable import InvariantCore
@testable import InvariantKit

@Suite("Scenario Tests")
struct ScenarioSmokeTests {
  @Test("Smoke test")
  func smoke() {
    #expect(1 + 1 == 2)
  }
}
