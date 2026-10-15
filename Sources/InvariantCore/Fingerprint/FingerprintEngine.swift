public import Foundation

public enum FingerprintError: Error, Equatable, Sendable {
  case directoryNotFound(URL)
  case gitError(String)
}

public struct FingerprintEngine: Sendable {
  private let gitClient: GitClient

  public init(gitClient: GitClient = GitClient()) {
    self.gitClient = gitClient
  }

  /// Computes the working tree git tree hash for a rule folder.
  public func computeFingerprint(repoRoot: URL, ruleId: String) async throws(FingerprintError) -> String {
    let relativePath = "invariants/rules/\(ruleId)"
    let fullURL = repoRoot.appendingPathComponent(relativePath)
    guard FileManager.default.fileExists(atPath: fullURL.path) else {
      throw FingerprintError.directoryNotFound(fullURL)
    }

    let tempIndexURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
      try? FileManager.default.removeItem(at: tempIndexURL)
    }

    do {
      return try await gitClient.computeTreeHash(
        repoRoot: repoRoot,
        directoryRelativePath: relativePath,
        tempIndexURL: tempIndexURL
      )
    } catch {
      throw FingerprintError.gitError("Failed to compute tree hash for \(relativePath): \(error)")
    }
  }
}
