import Testing

@testable import InvariantCore

@Suite("Core Tests")
struct InvariantCoreSmokeTests {
  @Test("Smoke test")
  func smoke() {
    _ = InvariantCoreMarker()
    #expect(Bool(true))
  }
}
