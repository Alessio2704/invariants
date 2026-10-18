public import Foundation

public enum FingerprintError: Error, Equatable, Sendable {
  case directoryNotFound(URL)
  case gitError(String)
}

public enum FingerprintEngine: Sendable {
  /// Computes the working tree git tree hash for a rule folder.
  public static func computeFingerprint(
    ruleId: String
  ) async throws(FingerprintError) -> String {
    let repoRoot = RepoLocator.current
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
      return try await GitClient.computeTreeHash(
        directoryRelativePath: relativePath,
        tempIndexURL: tempIndexURL
      )
    } catch {
      throw FingerprintError.gitError("Failed to compute tree hash for \(relativePath): \(error)")
    }
  }
}
