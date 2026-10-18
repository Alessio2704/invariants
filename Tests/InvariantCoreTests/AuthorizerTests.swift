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
}
