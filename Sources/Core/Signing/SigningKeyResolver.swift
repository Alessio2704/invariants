public import Foundation

/// Resolves cryptographic signing keys from disk or environment for repository operations.
public enum SigningKeyResolver: Sendable {
  /// Resolves the signing key URL strictly by precedence: customPath -> INVARIANTS_KEY -> default signing key.
  /// Strictly throws SigningError.keyNotFound if a specified path or default key does not exist on disk.
  public static func resolveKey(
    customPath: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws(SigningError) -> URL {
    if let customPath, !customPath.isEmpty {
      let expanded = (customPath as NSString).expandingTildeInPath
      let url = URL(fileURLWithPath: expanded)
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw SigningError.keyNotFound(expanded)
      }
      return url
    }

    if let envPath = environment["INVARIANTS_KEY"], !envPath.isEmpty {
      let expanded = (envPath as NSString).expandingTildeInPath
      let url = URL(fileURLWithPath: expanded)
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw SigningError.keyNotFound(expanded)
      }
      return url
    }

    let defaultKey = SystemEnvironment.defaultSigningKeyURL
    guard FileManager.default.fileExists(atPath: defaultKey.path) else {
      throw SigningError.keyNotFound(defaultKey.path)
    }
    return defaultKey
  }
}
