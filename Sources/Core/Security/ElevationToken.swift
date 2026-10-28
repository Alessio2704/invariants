public import Foundation

/// An unforgeable capability token proving root privilege elevation was authorized by Authorizer.
public struct ElevationToken: CapabilityToken, Sendable, Equatable {
  /// The timestamp when elevation was authorized.
  public let authorizedAt: Date

  /// The expiration interval in seconds before the elevation token expires (default 300s = 5 minutes).
  public let expirationInterval: TimeInterval

  /// Returns true if the token is still within its validity window.
  public var isValid: Bool {
    Date().timeIntervalSince(authorizedAt) < expirationInterval
  }

  /// Explicitly internal initializer restricted to Authorizer.
  internal init(
    authorizedAt: Date,
    expirationInterval: TimeInterval
  ) {
    self.authorizedAt = authorizedAt
    self.expirationInterval = expirationInterval
  }

  /// Verifies that the token has not expired.
  public func validateFreshness() throws(SystemError) {
    guard isValid else {
      throw SystemError.cryptographicError("Elevation authorization token has expired.")
    }
  }
}
