// periphery:ignore:all
public import Foundation

/// A capability token proving authorized access with a validity window.
public protocol CapabilityToken: Sendable {
  /// The timestamp when the authorization occurred.
  var authorizedAt: Date { get }

  /// The expiration interval in seconds before the token expires.
  var expirationInterval: TimeInterval { get }

  /// Returns true if the token is still within its validity window.
  var isValid: Bool { get }

  /// Verifies that the token has not expired.
  func validateFreshness() throws(SystemError)
}

extension CapabilityToken {
  /// Returns true if the token is still within its validity window.
  public var isValid: Bool {
    Date().timeIntervalSince(authorizedAt) < expirationInterval
  }
}
