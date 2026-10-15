import Testing

@testable import InvariantKit

@Suite("Kit Tests")
struct InvariantKitSmokeTests {
  @Test("Smoke test")
  func smoke() {
    _ = InvariantKitMarker()
    #expect(Bool(true))
  }
}
