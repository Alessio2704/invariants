public import Foundation

/// Errors that occur during repository discovery.
public enum RepoLocatorError: LocalizedError, Equatable, Sendable {
  case notInsideGitRepository

  public var errorDescription: String? {
    switch self {
    case .notInsideGitRepository:
      return "Not inside a git repository."
    }
  }
}

/// Manages repository root resolution and task-local ambient scoping.
public enum RepoLocator: Sendable {
  @TaskLocal private static var _current: URL?

  /// Returns the current ambient repository root URL.
  ///
  /// - Precondition: Must be called within a `RepoLocator.withRepoRoot` scope.
  ///   Fails fast with `preconditionFailure` if accessed outside an active repository context.
  public static var current: URL {
    guard let root = _current else {
      preconditionFailure(
        "CRITICAL ARCHITECTURAL VIOLATION: Attempted to access RepoLocator.current without an active "
          + "repository context. Ensure the caller is scoped within RepoLocator.withRepoRoot(_:)."
      )
    }
    return root
  }

  /// Whether an ambient repository root is currently bound in the active task hierarchy.
  public static var hasCurrent: Bool {
    _current != nil
  }

  /// Executes an asynchronous operation within the scoped context of a repository root URL.
  public static func withRepoRoot<R>(_ url: URL, operation: () async throws -> R) async rethrows -> R {
    try await $_current.withValue(url.standardizedFileURL) {
      try await operation()
    }
  }

  /// Executes a synchronous operation within the scoped context of a repository root URL.
  public static func withRepoRoot<R>(_ url: URL, operation: () throws -> R) rethrows -> R {
    try $_current.withValue(url.standardizedFileURL) {
      try operation()
    }
  }

  /// Discovers the enclosing git repository root directory from `startURL` or throws an error.
  public static func discover(
    from startURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  ) throws(RepoLocatorError) -> URL {
    var current = startURL.standardizedFileURL
    while true {
      let gitMarker = current.appendingPathComponent(".git")
      if FileManager.default.fileExists(atPath: gitMarker.path) {
        return current
      }
      if current.path == "/" {
        throw RepoLocatorError.notInsideGitRepository
      }
      let parent = current.deletingLastPathComponent().standardizedFileURL
      if parent.path == current.path {
        throw RepoLocatorError.notInsideGitRepository
      }
      current = parent
    }
  }

  /// Locates the enclosing git repository root directory, returning `nil` if not inside a git repository.
  /// If an ambient repository root is already bound, returns `current`.
  public static func findRepoRoot(
    from startURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  ) -> URL? {
    if let bound = _current {
      return bound
    }
    return try? discover(from: startURL)
  }
}
