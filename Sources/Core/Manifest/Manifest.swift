public import Foundation

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

public enum ManifestError: Error, Equatable, Sendable, CustomStringConvertible {
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
  case missingTargetInRegistryLanguages(TargetLanguage)
  case emptyCodes
  case codeNotTestedByFixtures(String)
  case undeclaredCodeEmitted(code: String, ruleId: String)

  public var description: String {
    switch self {
    case .fileNotFound(let url):
      return "Manifest file not found: \(url.path)"
    case .invalidJSON(let msg):
      return "Invalid JSON in manifest: \(msg)"
    case .unknownKey(let key):
      return "Unknown key in manifest: '\(key)'"
    case .idMismatch(let expected, let found):
      return "Manifest ID mismatch: expected '\(expected)', found '\(found)'"
    case .missingField(let field):
      return "Missing required field in manifest: '\(field)'"
    case .emptyTargets:
      return "Manifest targets list cannot be empty"
    case .invalidTarget(let target):
      return "Invalid target language: '\(target)'"
    case .missingTargetScope(let target):
      return "Missing scope configuration for target '\(target.rawValue)'"
    case .emptyScopeInclude(let target):
      return "Scope include patterns for target '\(target.rawValue)' cannot be empty"
    case .scopeMatchesNoFiles(let target, let patterns):
      return "Scope for target '\(target.rawValue)' matches no files with patterns: \(patterns)"
    case .missingRuleFile(let target, let filename):
      return "Missing required rule implementation for \(target.rawValue): '\(filename)'"
    case .forbiddenRuleFile(let target, let filename):
      return "Forbidden rule file for undeclared target \(target.rawValue): '\(filename)'"
    case .missingFixtureFolder(let folder):
      return "Missing required fixture folder: '\(folder)'"
    case .emptyFixtureFolder(let folder):
      return "Fixture folder is empty: '\(folder)'"
    case .missingTargetInRegistryLanguages(let target):
      return "Target '\(target.rawValue)' declared in rule is not configured in registry.languages"
    case .emptyCodes:
      return "Manifest codes dictionary cannot be empty"
    case .codeNotTestedByFixtures(let code):
      return "Rule manifest code '\(code)' is not covered by any should_fail fixture"
    case .undeclaredCodeEmitted(let code, let ruleId):
      return "Rule '\(ruleId)' emitted undeclared violation code '\(code)'"
    }
  }
}
