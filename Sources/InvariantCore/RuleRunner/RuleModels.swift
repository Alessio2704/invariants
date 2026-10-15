public import Foundation

/// Request payload passed to rule subprocesses.
public struct RuleRequest: Sendable, Codable {
  public let mode: String  // "repo" or "fixture"
  public let repoRoot: String
  public let ruleDir: String
  public let files: [String]
  public let project: ProjectConfig?

  public init(
    mode: String,
    repoRoot: String,
    ruleDir: String,
    files: [String],
    project: ProjectConfig? = nil
  ) {
    self.mode = mode
    self.repoRoot = repoRoot
    self.ruleDir = ruleDir
    self.files = files
    self.project = project
  }
}

/// A violation emitted by a rule.
public struct ReportedViolation: Sendable, Codable, Equatable, Hashable {
  public let code: String
  public let file: String
  public let line: Int
  public let column: Int
  public let message: String
  public let fix: String

  public init(
    code: String,
    file: String,
    line: Int,
    column: Int,
    message: String,
    fix: String
  ) {
    self.code = code
    self.file = file
    self.line = line
    self.column = column
    self.message = message
    self.fix = fix
  }
}

public enum RuleRunnerError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
  case ruleCrashed(exitCode: Int32, stderr: String)
  case ruleHung(timeoutSeconds: Double)
  case indexStale(String)
  case invalidOutput(String)
  case executableBuildFailed(String)
  case nodeNotFound
  case kitNotFound(String)
  case systemError(String)

  public var errorDescription: String? {
    switch self {
    case .ruleCrashed(let exitCode, let stderr):
      return "RULE CRASHED (exit code \(exitCode)): \(stderr)"
    case .ruleHung(let timeout):
      return "RULE HUNG (timed out after \(Int(timeout))s)"
    case .indexStale(let msg):
      return "INDEX STALE — \(msg)"
    case .invalidOutput(let msg):
      return "Invalid rule output: \(msg)"
    case .executableBuildFailed(let msg):
      return "Failed to build rule executable: \(msg)"
    case .nodeNotFound:
      return "Node.js executable not found"
    case .kitNotFound(let msg):
      return "Rule kit not found: \(msg)"
    case .systemError(let msg):
      return "System error: \(msg)"
    }
  }

  public var description: String {
    errorDescription ?? "RuleRunnerError"
  }
}
