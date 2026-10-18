public import Foundation

/// Resolves or prompts for the cryptographic signing key for repository operations.
public enum SigningKeyResolver: Sendable {
  /// Resolves the dedicated Invariants signing key.
  /// 1. Uses explicit customPath if passed and valid.
  /// 2. Uses dedicated default key at ~/.ssh/invariants_p256 (or .pub).
  /// 3. Returns nil if not found.
  public static func resolveSigningKey(customPath: String? = nil) -> URL? {
    if let customPath, !customPath.isEmpty {
      let url = URL(fileURLWithPath: (customPath as NSString).expandingTildeInPath)
      if FileManager.default.fileExists(atPath: url.path) {
        return url
      }
    }

    let defaultKey = SystemEnvironment.defaultSigningKeyURL
    if FileManager.default.fileExists(atPath: defaultKey.path) {
      return defaultKey
    }

    return nil
  }
}
