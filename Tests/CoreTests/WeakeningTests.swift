import Foundation
import Testing

@testable import Core

@Suite("Weakening & Policy Detector", .tags(.unit))
struct WeakeningTests {
  @Test("Detects all red flags when an invariant is weakened")
  func detectsWeakeningRedFlags() {
    let oldManifest = RuleManifest(
      id: "no-raw-text",
      summary: "summary",
      targets: [.swift, .ts],
      scope: [
        .swift: [
          "ios": TargetScope(include: ["App/**/*.swift"], exclude: ["App/Previews/**"]),
          "vapor": TargetScope(include: ["Server/**/*.swift"]),
        ]
      ],
      codes: [
        "RAW-TEXT": "Desc",
        "OLD-CODE": "Removed",
      ]
    )

    // Weakened new manifest: removed OLD-CODE, removed TS target, removed vapor unit, added exclude to ios
    let newManifest = RuleManifest(
      id: "no-raw-text",
      summary: "summary",
      targets: [.swift],
      scope: [
        .swift: [
          "ios": TargetScope(include: ["App/**/*.swift"], exclude: ["App/Previews/**", "App/SneakyExclude/**"])
        ]
      ],
      codes: [
        "RAW-TEXT": "Desc"
      ]
    )

    let oldCase = FixtureCase(
      id: "case1",
      rootURL: URL(fileURLWithPath: "/tmp"),
      files: [],
      expectedViolations: [
        ExpectedViolation(relativePath: "case1.swift", line: 10, code: "RAW-TEXT"),
        ExpectedViolation(relativePath: "case1.swift", line: 20, code: "RAW-TEXT"),
      ],
      isShouldPass: false,
      target: .swift
    )

    // Weakened case: removed line 20 expectation
    let newCase = FixtureCase(
      id: "case1",
      rootURL: URL(fileURLWithPath: "/tmp"),
      files: [],
      expectedViolations: [
        ExpectedViolation(relativePath: "case1.swift", line: 10, code: "RAW-TEXT")
      ],
      isShouldPass: false,
      target: .swift
    )

    let report = WeakeningDetector.detect(
      ruleId: "no-raw-text",
      oldManifest: oldManifest,
      newManifest: newManifest,
      oldCases: [oldCase],
      newCases: [newCase],
      oldRepoViolationsCount: 5,
      newRepoViolationsCount: 3
    )

    #expect(report.hasRedFlags)
    let redMessages = report.items.filter { $0.severity == .red }.map { $0.message }

    #expect(redMessages.contains(where: { $0.contains("OLD-CODE") }))
    #expect(redMessages.contains(where: { $0.contains("ts") }))
    #expect(redMessages.contains(where: { $0.contains("[swift.vapor] unit scope was removed") }))
    #expect(redMessages.contains(where: { $0.contains("[swift.ios] exclude pattern added: 'App/SneakyExclude/**'") }))
    #expect(redMessages.contains(where: { $0.contains("case1.swift:20") }))
    #expect(redMessages.contains(where: { $0.contains("Repo violation count dropped") }))
  }

  @Test("Detects green flags when fixtures are added legitimately")
  func detectsLegitimateGreenFlags() {
    let manifest = RuleManifest(
      id: "no-raw-text",
      summary: "summary",
      targets: [.swift],
      scope: [.swift: ["main": TargetScope(include: ["**/*.swift"])]],
      codes: ["RAW-TEXT": "Desc"]
    )

    let oldCases: [FixtureCase] = []
    let newPassCase = FixtureCase(
      id: "legit_case",
      rootURL: URL(fileURLWithPath: "/tmp"),
      files: [],
      expectedViolations: [],
      isShouldPass: true,
      target: .swift
    )

    let report = WeakeningDetector.detect(
      ruleId: "no-raw-text",
      oldManifest: manifest,
      newManifest: manifest,
      oldCases: oldCases,
      newCases: [newPassCase]
    )

    #expect(!report.hasRedFlags)
    #expect(report.hasGreenFlags)
    #expect(report.items.contains { $0.category == "Fixture" && $0.message.contains("legit_case") })
  }
}
