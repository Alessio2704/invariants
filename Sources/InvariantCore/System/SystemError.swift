import Foundation

/// Errors produced during system and subprocess interactions.
public enum SystemError: Error, Equatable, Sendable {
  case executableNotFound(String)
  case processFailed(executable: String, arguments: [String], exitCode: Int32, stderr: String)
  case processTimedOut(executable: String, timeoutSeconds: Double)
  case fileIOError(String)
  case secureEnclaveUnavailable(String)
  case cryptographicError(String)
}
