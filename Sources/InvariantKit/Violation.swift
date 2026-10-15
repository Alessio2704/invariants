import Foundation

/// Represents an architectural violation diagnosed by an invariant rule.
public struct Violation: Sendable, Codable, Equatable, Hashable {
  /// The unique rule violation code, e.g. "RAW-TEXT".
  public let code: String

  /// The relative path of the violating file.
  public let file: String

  /// The 1-indexed line number where the violation occurred.
  public let line: Int

  /// The 1-indexed column number where the violation occurred.
  public let column: Int

  /// A clear description of the violation.
  public let message: String

  /// An actionable suggestion on how to remediate the violation.
  public let fix: String

  /// Creates a new violation diagnosis.
  /// - Parameters:
  ///   - code: The unique rule violation code.
  ///   - file: The relative path of the violating file.
  ///   - line: The 1-indexed line number.
  ///   - column: The 1-indexed column number.
  ///   - message: A clear description of the issue.
  ///   - fix: Suggested remediation steps.
  public init(
    code: String,
    file: String,
    line: Int = 1,
    column: Int = 1,
    message: String,
    fix: String = ""
  ) {
    self.code = code
    self.file = file
    self.line = line
    self.column = column
    self.message = message
    self.fix = fix
  }
}
