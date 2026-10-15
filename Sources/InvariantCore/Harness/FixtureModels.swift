public import Foundation

/// Represents an expectation parsed from annotations.
public struct ExpectedViolation: Sendable, Hashable, Equatable {
  public let relativePath: String
  public let line: Int
  public let code: String

  public init(relativePath: String, line: Int, code: String) {
    self.relativePath = relativePath
    self.line = line
    self.code = code
  }
}

/// A discovered fixture case (single file or folder).
public struct FixtureCase: Sendable {
  public let id: String
  public let rootURL: URL
  public let files: [URL]
  public let expectedViolations: [ExpectedViolation]
  public let isShouldPass: Bool
  public let target: TargetLanguage

  public init(
    id: String,
    rootURL: URL,
    files: [URL],
    expectedViolations: [ExpectedViolation],
    isShouldPass: Bool,
    target: TargetLanguage
  ) {
    self.id = id
    self.rootURL = rootURL
    self.files = files
    self.expectedViolations = expectedViolations
    self.isShouldPass = isShouldPass
    self.target = target
  }
}

public enum HarnessError: Error, Equatable, Sendable {
  case annotationsForbiddenInShouldPass(caseId: String, file: String, line: Int)
  case expectedViolationsMissing(caseId: String, missing: [ExpectedViolation])
  case unexpectedViolationsReported(caseId: String, unexpected: [ExpectedViolation])
  case ruleCrashed(caseId: String, message: String)
  case ruleHung(caseId: String)
  case missingCodeCoverage(codes: [String])
  case ioError(String)
}
