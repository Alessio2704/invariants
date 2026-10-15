import Foundation
import Testing

@testable import InvariantCore

enum InvalidManifestCase: String, CaseIterable, Sendable {
  case unknownKey = """
    {
      "id": "toy",
      "summary": "Toy rule",
      "targets": ["swift"],
      "scope": { "swift": { "include": ["**/*.swift"] } },
      "codes": { "C1": "Code 1" },
      "extraUnknownKey": true
    }
    """

  case emptyTargets = """
    {
      "id": "toy",
      "summary": "Toy rule",
      "targets": [],
      "scope": {},
      "codes": { "C1": "Code 1" }
    }
    """

  case missingScopeForTarget = """
    {
      "id": "toy",
      "summary": "Toy rule",
      "targets": ["swift"],
      "scope": {},
      "codes": { "C1": "Code 1" }
    }
    """

  case emptyCodes = """
    {
      "id": "toy",
      "summary": "Toy rule",
      "targets": ["swift"],
      "scope": { "swift": { "include": ["**/*.swift"] } },
      "codes": {}
    }
    """

  case unknownScopeKey = """
    {
      "id": "toy",
      "summary": "Toy rule",
      "targets": ["swift"],
      "scope": { "swift": { "include": ["**/*.swift"], "forbiddenField": 123 } },
      "codes": { "C1": "Code 1" }
    }
    """
}

@Suite("Manifest & Schema", .tags(.unit))
struct ManifestTests {
  @Test("Valid manifest parses correctly")
  func validManifestParsing() throws {
    let json = """
      {
        "id": "toy",
        "summary": "A sample toy rule",
        "targets": ["swift", "ts"],
        "scope": {
          "swift": { "include": ["App/**/*.swift"], "exclude": ["App/Previews/**"] },
          "ts": { "include": ["src/**/*.ts"] }
        },
        "codes": {
          "TOY-01": "Toy violation 1",
          "TOY-02": "Toy violation 2"
        }
      }
      """
    let data = Data(json.utf8)
    let manifest = try ManifestParser.parse(data: data, expectedId: "toy")
    #expect(manifest.id == "toy")
    #expect(manifest.targets == [.swift, .ts])
    #expect(manifest.codes.count == 2)
    #expect(manifest.scope[.swift]?.include == ["App/**/*.swift"])
    #expect(manifest.scope[.swift]?.exclude == ["App/Previews/**"])
  }

  @Test("ID mismatch is rejected")
  func idMismatch() {
    let json = """
      {
        "id": "toy",
        "summary": "Toy",
        "targets": ["swift"],
        "scope": { "swift": { "include": ["**/*.swift"] } },
        "codes": { "C1": "Desc" }
      }
      """
    #expect(throws: ManifestError.self) {
      try ManifestParser.parse(data: Data(json.utf8), expectedId: "different-id")
    }
  }

  @Test("Parameterized rejection of malformed manifests", arguments: InvalidManifestCase.allCases)
  func malformedManifestsRejected(invalidCase: InvalidManifestCase) {
    let data = Data(invalidCase.rawValue.utf8)
    #expect(throws: ManifestError.self) {
      try ManifestParser.parse(data: data)
    }
  }

  @Test("Glob matcher accurately matches paths and excludes")
  func globMatcher() {
    guard let matcher = GlobMatcher(pattern: "App/**/*.swift") else {
      Issue.record("Failed to create GlobMatcher")
      return
    }
    #expect(matcher.matches("App/Views/MainView.swift"))
    #expect(matcher.matches("App/Deep/Nested/File.swift"))
    #expect(!matcher.matches("Server/Main.swift"))
    #expect(!matcher.matches("App/Views/README.md"))

    guard let excludeMatcher = GlobMatcher(pattern: "App/Previews/**") else {
      Issue.record("Failed to create exclude matcher")
      return
    }
    #expect(excludeMatcher.matches("App/Previews/ViewPreview.swift"))
    #expect(!excludeMatcher.matches("App/Views/MainView.swift"))
  }
}
