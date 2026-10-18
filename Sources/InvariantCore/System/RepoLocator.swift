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

/// Discovers the enclosing git repository from the current working directory.
public enum RepoLocator: Sendable {
  /// Locates the enclosing git repository root directory from startURL (defaults to current working directory).
  public static func findRepoRoot(
    from startURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  ) -> URL? {
    var current = startURL.standardizedFileURL
    while true {
      let gitMarker = current.appendingPathComponent(".git")
      if FileManager.default.fileExists(atPath: gitMarker.path) {
        return current
      }
      let parent = current.deletingLastPathComponent()
      if parent.path == current.path {
        return nil
      }
      current = parent
    }
  }

  /// Locates the enclosing git repository root directory or throws an error.
  public static func requireRepoRoot(
    from startURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  ) throws(RepoLocatorError) -> URL {
    guard let root = findRepoRoot(from: startURL) else {
      throw RepoLocatorError.notInsideGitRepository
    }
    return root
  }
}
