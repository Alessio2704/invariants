import Foundation
import Testing

@testable import InvariantCore

@Suite("Engine Version Tests", .tags(.unit))
struct EngineVersionTests {

  @Test("EngineVersion.current is a non-empty, valid semantic version string")
  func engineVersionSemverFormat() {
    let current = EngineVersion.current
    #expect(!current.isEmpty)

    let parsed = Semver(string: current)
    #expect(parsed != nil)
    #expect(parsed?.description == current)
  }

  @Test("EngineVersion.semver matches parsed current version")
  func engineVersionSemverProperty() {
    let semver = EngineVersion.semver
    #expect(semver.description == EngineVersion.current)
  }

  @Test("EngineVersion.defaultRange formats caret range requirement correctly")
  func engineVersionDefaultRange() {
    let range = EngineVersion.defaultRange
    #expect(range == "^\(EngineVersion.current)")

    let semverRange = SemverRange(range)
    #expect(semverRange.satisfies(EngineVersion.semver))
  }
}
