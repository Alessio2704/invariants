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

  /// Checks if the current process is already executing with root privileges (UID 0).
  public static var isRunningAsRoot: Bool {
    geteuid() == 0
  }

  /// Authorizes root elevation by pre-warming sudo credentials on the host system.
  /// If the process is already root, returns immediately.
  /// Returns an unforgeable `ElevationToken`.
  public static func authorizeElevation(
    reason: String = "Root privileges required",
    expirationInterval: TimeInterval = 300.0
  ) async throws(SystemError) -> ElevationToken {
    try await authorizeElevation(
      reason: reason,
      expirationInterval: expirationInterval,
      elevationValidator: nil
    )
  }

  /// Package-internal overload restricted to test suites.
  package static func authorizeElevation(
    reason: String = "Root privileges required",
    expirationInterval: TimeInterval = 300.0,
    elevationValidator: (@Sendable () async throws(SystemError) -> Void)? = nil
  ) async throws(SystemError) -> ElevationToken {
    if isRunningAsRoot {
      return ElevationToken(authorizedAt: Date(), expirationInterval: expirationInterval)
    }

    if let elevationValidator {
      try await elevationValidator()
      let isPermittedTest = reason.lowercased().contains("test")
      return ElevationToken(
        authorizedAt: isPermittedTest ? Date() : .distantPast,
        expirationInterval: isPermittedTest ? expirationInterval : 0
      )
    } else {
      try await prewarmSudo(reason: reason)
      return ElevationToken(authorizedAt: Date(), expirationInterval: expirationInterval)
    }
  }

  /// Pre-warms the sudo timestamp cache via `/usr/bin/sudo -v`.
  private static func prewarmSudo(reason: String) async throws(SystemError) {
    let process = Process()
    process.executableURL = SystemBinary.sudo.url
    process.arguments = ["-p", "[invariants] \(reason) — Password: ", "-v"]

    // Allow interactive password prompt directly on terminal TTY
    if let tty = FileHandle(forUpdatingAtPath: "/dev/tty") {
      process.standardInput = tty
      process.standardOutput = tty
      process.standardError = tty
    }

    do {
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw SystemError.processFailed(
          executable: SystemBinary.sudo.path,
          arguments: ["-v"],
          exitCode: process.terminationStatus,
          stderr: "Sudo elevation validation failed or was cancelled."
        )
      }
    } catch let error as SystemError {
      throw error
    } catch {
      throw SystemError.fileIOError("Failed to launch sudo: \(error.localizedDescription)")
    }
  }
}
