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

  /// Generates a dedicated Touch ID signing key in Apple Secure Enclave.
  @discardableResult
  public static func generateHardwareKey(
    at destinationURL: URL = SystemEnvironment.defaultSigningKeyURL,
    force: Bool = false
  ) async throws -> URL {
    let pubURL = destinationURL.appendingPathExtension("pub")

    if FileManager.default.fileExists(atPath: destinationURL.path) && !force {
      return destinationURL
    }

    let token = try await Authorizer.authorizeBiometrics(
      reason: "Touch your Touch ID sensor to enroll your hardware signing key in Apple Secure Enclave"
    )
    try SigningClient.generateSigningKey(at: destinationURL, token: token)

    guard FileManager.default.fileExists(atPath: pubURL.path) else {
      throw SystemError.cryptographicError("Could not create public key at \(pubURL.path)")
    }

    return destinationURL
  }
}
