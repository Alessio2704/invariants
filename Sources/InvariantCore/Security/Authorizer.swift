import CryptoKit
public import Foundation
import LocalAuthentication

/// Centralized authorization engine evaluating biometric and privilege requirements.
public enum Authorizer: Sendable {
  /// Evaluates device owner biometric presence (Touch ID / Face ID / Apple Watch) using Apple LocalAuthentication.
  /// Strictly requires Apple Secure Enclave hardware and valid biometric authorization.
  /// Returns a fresh, unforgeable `BiometricAuthToken`.
  public static func authorizeBiometrics(
    reason: String,
    expirationInterval: TimeInterval = 30.0
  ) async throws(SystemError) -> BiometricAuthToken {
    try await authorizeBiometrics(
      reason: reason,
      expirationInterval: expirationInterval,
      context: LAContext()
    )
  }

  /// Internal overload for dependency injection in @testable test suites.
  static func authorizeBiometrics(
    reason: String,
    expirationInterval: TimeInterval = 30.0,
    context: LAContext
  ) async throws(SystemError) -> BiometricAuthToken {
    guard SecureEnclave.isAvailable else {
      throw SystemError.secureEnclaveUnavailable(
        "Apple Secure Enclave hardware is not available on this machine."
      )
    }

    var authError: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &authError) else {
      let desc = authError?.localizedDescription ?? "Touch ID is not configured or available."
      throw SystemError.cryptographicError("Touch ID biometric verification is required: \(desc)")
    }

    context.localizedReason = reason

    do {
      let authorized = try await context.evaluatePolicy(
        .deviceOwnerAuthenticationWithBiometrics,
        localizedReason: reason
      )
      guard authorized else {
        throw SystemError.cryptographicError("Touch ID biometric verification failed.")
      }
    } catch {
      throw SystemError.cryptographicError("Touch ID biometric verification failed: \(error.localizedDescription)")
    }

    return BiometricAuthToken(
      context: context,
      authorizedAt: Date(),
      expirationInterval: expirationInterval
    )
  }
}
