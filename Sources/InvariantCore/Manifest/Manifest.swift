public import Foundation

/// Target language supported by Invariants.
public enum TargetLanguage: String, Sendable, Codable, CaseIterable {
  case swift
  case ts
}

/// Scope definition for a specific target.
public struct TargetScope: Sendable, Equatable, Codable {
  public var include: [String]
  public var exclude: [String]?

  public init(include: [String], exclude: [String]? = nil) {
    self.include = include
    self.exclude = exclude
  }
}

/// Strict manifest model for `invariants/rules/<id>/manifest.json`.
public struct RuleManifest: Sendable, Equatable {
  public var id: String
  public var summary: String
  public var targets: [TargetLanguage]
  public var scope: [TargetLanguage: TargetScope]
  public var codes: [String: String]

  public init(
    id: String,
    summary: String,
    targets: [TargetLanguage],
    scope: [TargetLanguage: TargetScope],
    codes: [String: String]
  ) {
    self.id = id
    self.summary = summary
    self.targets = targets
    self.scope = scope
    self.codes = codes
  }
}

public enum ManifestError: Error, Equatable, Sendable {
  case fileNotFound(URL)
  case invalidJSON(String)
  case unknownKey(String)
  case idMismatch(expected: String, found: String)
  case missingField(String)
  case emptyTargets
  case invalidTarget(String)
  case missingTargetScope(TargetLanguage)
  case emptyScopeInclude(TargetLanguage)
  case scopeMatchesNoFiles(TargetLanguage, [String])
  case missingRuleFile(TargetLanguage, String)
  case forbiddenRuleFile(TargetLanguage, String)
  case missingFixtureFolder(String)
  case emptyFixtureFolder(String)
  case missingTargetInRegistryProject(TargetLanguage)
  case emptyCodes
  case codeNotTestedByFixtures(String)
  case undeclaredCodeEmitted(code: String, ruleId: String)
}
