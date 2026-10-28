public import Foundation
@preconcurrency import LocalAuthentication

/// An unforgeable capability token proving biometric physical presence was authenticated by Apple LocalAuthentication.
public struct BiometricAuthToken: CapabilityToken, @unchecked Sendable {
  /// The timestamp when the biometric authorization occurred.
  public let authorizedAt: Date

  /// The expiration interval in seconds before the token expires.
  public let expirationInterval: TimeInterval

  /// The underlying authentication context, preserved for Apple CryptoKit Secure Enclave operations.
  internal let context: LAContext

  /// Returns true if the token is still within its validity window.
  public var isValid: Bool {
    Date().timeIntervalSince(authorizedAt) < expirationInterval
  }

  /// Explicitly internal initializer restricted to Authorizer.
  internal init(
    context: LAContext,
    authorizedAt: Date,
    expirationInterval: TimeInterval
  ) {
    self.context = context
    self.authorizedAt = authorizedAt
    self.expirationInterval = expirationInterval
  }

  /// Verifies that the token has not expired.
  public func validateFreshness() throws(SystemError) {
    guard isValid else {
      throw SystemError.cryptographicError("Biometric authorization token has expired.")
    }
  }
}
