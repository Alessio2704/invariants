import Foundation
import Testing

@testable import Core

enum InvalidManifestCase: String, CaseIterable, Sendable {
  case unknownKey = """
    {
      "id": "toy",
      "summary": "Toy rule",
      "targets": ["swift"],
      "scope": { "swift": { "main": { "include": ["**/*.swift"] } } },
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

  case emptyTargetUnits = """
    {
      "id": "toy",
      "summary": "Toy rule",
      "targets": ["swift"],
      "scope": { "swift": {} },
      "codes": { "C1": "Code 1" }
    }
    """

  case emptyCodes = """
    {
      "id": "toy",
      "summary": "Toy rule",
      "targets": ["swift"],
      "scope": { "swift": { "main": { "include": ["**/*.swift"] } } },
      "codes": {}
    }
    """

  case unknownScopeKey = """
    {
      "id": "toy",
      "summary": "Toy rule",
      "targets": ["swift"],
      "scope": { "swift": { "main": { "include": ["**/*.swift"], "forbiddenField": 123 } } },
      "codes": { "C1": "Code 1" }
    }
    """
}

@Suite("Manifest & Schema", .tags(.unit))
struct ManifestTests {
  @Test("Valid manifest parses correctly with unit-scoped targets")
  func validManifestParsing() throws {
    let json = """
      {
        "id": "toy",
        "summary": "A sample toy rule",
        "targets": ["swift", "ts"],
        "scope": {
          "swift": {
            "ios": { "include": ["App/**/*.swift"], "exclude": ["App/Previews/**"] },
            "vapor": { "include": ["Server/**/*.swift"] }
          },
          "ts": {
            "web": { "include": ["src/**/*.ts"] },
            "bff": { "include": ["bff/**/*.ts"] }
          }
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
    #expect(manifest.scope[.swift]?["ios"]?.include == ["App/**/*.swift"])
    #expect(manifest.scope[.swift]?["ios"]?.exclude == ["App/Previews/**"])
    #expect(manifest.scope[.swift]?["vapor"]?.include == ["Server/**/*.swift"])
    #expect(manifest.scope[.ts]?["web"]?.include == ["src/**/*.ts"])
    #expect(manifest.scope[.ts]?["bff"]?.include == ["bff/**/*.ts"])
  }

  @Test("ID mismatch is rejected")
  func idMismatch() {
    let json = """
      {
        "id": "toy",
        "summary": "Toy",
        "targets": ["swift"],
        "scope": { "swift": { "main": { "include": ["**/*.swift"] } } },
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

  @Test("ManifestValidator rejects unit missing from registry.ast")
  func manifestValidatorMissingUnitInAST() throws {
    let manifest = RuleManifest(
      id: "rule1",
      summary: "Rule",
      targets: [.swift],
      scope: [.swift: ["vapor": TargetScope(include: ["Server/**/*.swift"])]],
      codes: ["C1": "Code 1"]
    )
    var ast = ASTConfig()
    ast[SwiftLanguage.self] = ["ios": SwiftLanguage.Config(indexStore: "ios/store")]
    let reg = Registry(languages: [.swift], ast: ast)

    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    // Create rule.swift and fixture folders
    try Data("// rule".utf8).write(to: tmpDir.appendingPathComponent("rule.swift"))
    let passDir = tmpDir.appendingPathComponent("should_pass/swift")
    let failDir = tmpDir.appendingPathComponent("should_fail/swift")
    try FileManager.default.createDirectory(at: passDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: failDir, withIntermediateDirectories: true)
    try Data("// pass".utf8).write(to: passDir.appendingPathComponent("case1.swift"))
    try Data("// fail".utf8).write(to: failDir.appendingPathComponent("case1.swift"))

    #expect {
      try ManifestValidator.validateStructure(
        ruleDirectory: tmpDir,
        manifest: manifest,
        registry: reg,
        isFixtureMode: false
      )
    } throws: { error in
      guard let err = error as? ManifestError, case .missingUnitInRegistryAST(let target, let unit) = err else {
        return false
      }
      return target == .swift && unit == "vapor"
    }
  }

  @Test("resolveScopedFilesByUnit accurately isolates files per unit")
  func resolveScopedFilesByUnitIsolation() throws {
    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    let iosDir = tmpDir.appendingPathComponent("ios/App")
    let vaporDir = tmpDir.appendingPathComponent("vapor/Sources")
    try fm.createDirectory(at: iosDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: vaporDir, withIntermediateDirectories: true)

    let iosFile = iosDir.appendingPathComponent("Client.swift")
    let vaporFile = vaporDir.appendingPathComponent("Server.swift")
    try Data("import Foundation".utf8).write(to: iosFile)
    try Data("import Vapor".utf8).write(to: vaporFile)

    RepoLocator.withRepoRoot(tmpDir) {
      let scopes: [String: TargetScope] = [
        "ios": TargetScope(include: ["ios/**/*.swift"]),
        "vapor": TargetScope(include: ["vapor/**/*.swift"]),
      ]
      let resolved = ManifestValidator.resolveScopedFilesByUnit(scopes: scopes, target: .swift)
      #expect(resolved["ios"]?.count == 1)
      #expect(resolved["ios"]?.first?.lastPathComponent == "Client.swift")
      #expect(resolved["vapor"]?.count == 1)
      #expect(resolved["vapor"]?.first?.lastPathComponent == "Server.swift")
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

  @Test("ManifestParser.load throws fileNotFound for nonexistent URL")
  func manifestLoadFileNotFound() {
    let nonExistentURL = URL(fileURLWithPath: "/nonexistent/manifest.json")
    #expect {
      try ManifestParser.load(from: nonExistentURL)
    } throws: { error in
      guard let err = error as? ManifestError, case .fileNotFound(let url) = err else { return false }
      return url == nonExistentURL && !err.description.isEmpty
    }
  }

  @Test("ManifestValidator validates codes coverage")
  func manifestValidatorCoverage() throws {
    let manifest = RuleManifest(
      id: "rule1",
      summary: "Rule",
      targets: [.swift],
      scope: [.swift: ["main": TargetScope(include: ["**/*.swift"])]],
      codes: ["C1": "Code 1", "C2": "Code 2"]
    )
    #expect {
      try ManifestValidator.validateCodesCoverage(manifest: manifest, coveredCodes: ["C1"])
    } throws: { error in
      guard let err = error as? ManifestError, case .codeNotTestedByFixtures(let code) = err else { return false }
      return code == "C2" && !err.description.isEmpty
    }

    // Full coverage passes
    try ManifestValidator.validateCodesCoverage(manifest: manifest, coveredCodes: ["C1", "C2"])
  }

  @Test("ManifestValidator rejects undeclared codes in reported violations")
  func manifestValidatorUndeclaredCode() throws {
    let manifest = RuleManifest(
      id: "rule1",
      summary: "Rule",
      targets: [.swift],
      scope: [.swift: ["main": TargetScope(include: ["**/*.swift"])]],
      codes: ["C1": "Code 1"]
    )
    let badViolation = ReportedViolation(
      code: "UNKNOWN", file: "foo.swift", line: 1, column: 1, message: "msg", fix: "")
    #expect {
      try ManifestValidator.validateReportedViolations(manifest: manifest, violations: [badViolation])
    } throws: { error in
      guard let err = error as? ManifestError, case .undeclaredCodeEmitted(let code, let ruleId) = err else {
        return false
      }
      return code == "UNKNOWN" && ruleId == "rule1" && !err.description.isEmpty
    }

    let goodViolation = ReportedViolation(code: "C1", file: "foo.swift", line: 1, column: 1, message: "msg", fix: "")
    try ManifestValidator.validateReportedViolations(manifest: manifest, violations: [goodViolation])
  }
}
