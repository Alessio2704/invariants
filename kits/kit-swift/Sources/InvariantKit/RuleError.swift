import Foundation

/// Errors that can be thrown during invariant rule evaluation.
public enum RuleError: Error, Sendable, Equatable {
  /// The index store is missing or older than modified source files.
  case indexStale(String)

  /// A file or asset could not be read or decoded.
  case ioError(String)

  /// A rule evaluation failed with an unexpected error.
  case evaluationError(String)
}
