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

  /// Resolves an explicit custom signing key path, expanding tilde if needed.
  /// Returns the URL if the file exists, nil otherwise.
  public static func resolveCustomSigningKey(customPath: String) -> URL? {
    guard !customPath.isEmpty else { return nil }
    let url = URL(fileURLWithPath: (customPath as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return nil
    }
    return url
  }

  /// Resolves the dedicated default Invariants signing key at ~/.ssh/invariants_p256.
  /// Returns the URL if the file exists, nil otherwise.
  public static func resolveDefaultSigningKey() -> URL? {
    let defaultKey = SystemEnvironment.defaultSigningKeyURL
    guard FileManager.default.fileExists(atPath: defaultKey.path) else {
      return nil
    }
    return defaultKey
  }
}
