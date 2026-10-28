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

public enum HarnessError: Error, Equatable, Sendable, CustomStringConvertible {
  case annotationsForbiddenInShouldPass(caseId: String, file: String, line: Int)
  case expectedViolationsMissing(caseId: String, missing: [ExpectedViolation])
  case unexpectedViolationsReported(caseId: String, unexpected: [ExpectedViolation])
  case ruleCrashed(caseId: String, message: String)
  case ruleHung(caseId: String)
  case missingCodeCoverage(codes: [String])
  case ioError(String)
  case expectationMismatch(caseId: String, message: String)
  case manifestError(String)

  public var description: String {
    switch self {
    case .annotationsForbiddenInShouldPass(let caseId, let file, let line):
      return "should_pass fixture '\(caseId)' contains illegal expectation annotation at \(file):\(line)"
    case .expectedViolationsMissing(let caseId, let missing):
      let details = missing.map { "\($0.code) at \($0.relativePath):\($0.line)" }.joined(separator: ", ")
      return "should_fail fixture '\(caseId)' missed expected violations: [\(details)]"
    case .unexpectedViolationsReported(let caseId, let unexpected):
      let details = unexpected.map { "\($0.code) at \($0.relativePath):\($0.line)" }.joined(separator: ", ")
      return "fixture '\(caseId)' emitted unexpected violations: [\(details)]"
    case .ruleCrashed(let caseId, let message):
      return "rule crashed on fixture '\(caseId)': \(message)"
    case .ruleHung(let caseId):
      return "rule timed out (hung) while executing fixture '\(caseId)'"
    case .missingCodeCoverage(let codes):
      return "rule manifest codes not covered by should_fail fixtures: \(codes.joined(separator: ", "))"
    case .ioError(let msg):
      return "fixture I/O error: \(msg)"
    case .expectationMismatch(let caseId, let msg):
      return "fixture '\(caseId)' expectation mismatch: \(msg)"
    case .manifestError(let msg):
      return "manifest fixture error: \(msg)"
    }
  }
}

extension FixtureCase {
  /// Evaluates reported violations against this fixture's expectations.
  public func evaluateExpectations(reportedViolations: [ReportedViolation]) -> HarnessError? {
    let reported = reportedViolations.map {
      ExpectedViolation(
        relativePath: URL(fileURLWithPath: $0.file).lastPathComponent,
        line: $0.line,
        code: $0.code
      )
    }

    if isShouldPass {
      if !reported.isEmpty {
        return .unexpectedViolationsReported(caseId: id, unexpected: reported)
      }
      return nil
    }

    let expectedSet = Set(expectedViolations)
    let reportedSet = Set(reported)

    let missing = Array(expectedSet.subtracting(reportedSet))
    let unexpected = Array(reportedSet.subtracting(expectedSet))

    if !missing.isEmpty {
      return .expectedViolationsMissing(caseId: id, missing: missing)
    }
    if !unexpected.isEmpty {
      return .unexpectedViolationsReported(caseId: id, unexpected: unexpected)
    }
    return nil
  }
}
