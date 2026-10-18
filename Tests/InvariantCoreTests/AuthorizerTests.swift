import Foundation
import Testing

@testable import InvariantCore

@Suite("Authorizer & BiometricAuthToken Tests", .tags(.unit))
struct AuthorizerTests {
  @Test("BiometricAuthToken validity and freshness check")
  func tokenFreshness() throws {
    let token = BiometricAuthToken.forTesting()

    #expect(token.isValid)
    try token.validateFreshness()
  }

  @Test("Expired BiometricAuthToken fails freshness validation")
  func expiredTokenFailsValidation() {
    let token = BiometricAuthToken.forTesting(
      authorizedAt: Date().addingTimeInterval(-45.0),
      expirationInterval: 30.0
    )

    #expect(!token.isValid)
    #expect(throws: SystemError.self) {
      try token.validateFreshness()
    }
  }

  @Test("BiometricAuthToken honors custom expiration interval")
  func customExpirationInterval() throws {
    let freshToken = BiometricAuthToken.forTesting(
      authorizedAt: Date(),
      expirationInterval: 5.0
    )
    #expect(freshToken.isValid)

    let expiredToken = BiometricAuthToken.forTesting(
      authorizedAt: Date().addingTimeInterval(-6.0),
      expirationInterval: 5.0
    )
    #expect(!expiredToken.isValid)
  }

  @Test("ElevationToken validity and freshness check")
  func elevationTokenFreshness() throws {
    let token = ElevationToken.forTesting()
    #expect(token.isValid)
    try token.validateFreshness()
  }

  @Test("Expired ElevationToken fails freshness validation")
  func expiredElevationTokenFailsValidation() {
    let token = ElevationToken.forTesting(
      authorizedAt: Date().addingTimeInterval(-400.0),
      expirationInterval: 300.0
    )
    #expect(!token.isValid)
    #expect(throws: SystemError.self) {
      try token.validateFreshness()
    }
  }

  @Test("Authorizer authorizeElevation with validator succeeds and issues valid ElevationToken")
  func authorizeElevationSuccess() async throws {
    final class CallTracker: @unchecked Sendable {
      var called = false
    }
    let tracker = CallTracker()
    let token = try await Authorizer.authorizeElevation(
      reason: "test elevation",
      elevationValidator: { () throws(SystemError) in
        tracker.called = true
      }
    )
    if !Authorizer.isRunningAsRoot {
      #expect(tracker.called)
    }
    #expect(token.isValid)
  }

  @Test("Authorizer authorizeElevation aborts when validator fails")
  func authorizeElevationFails() async throws {
    guard !Authorizer.isRunningAsRoot else { return }

    await #expect(throws: SystemError.self) {
      try await Authorizer.authorizeElevation(
        reason: "test failure",
        elevationValidator: { () throws(SystemError) in
          throw SystemError.processFailed(
            executable: "/usr/bin/sudo",
            arguments: ["-v"],
            exitCode: 1,
            stderr: "Cancelled"
          )
        }
      )
    }
  }

  @Test("Authorizer isRunningAsRoot accurately reports process UID")
  func isRunningAsRootMatchesUID() {
    #expect(Authorizer.isRunningAsRoot == (geteuid() == 0))
  }
}
