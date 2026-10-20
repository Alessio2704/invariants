public import Foundation

/// Resolves cryptographic signing keys from disk for repository operations.
public enum SigningKeyResolver: Sendable {
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
