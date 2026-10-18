import Foundation
import LocalAuthentication

@testable import InvariantCore

extension BiometricAuthToken {
  static func forTesting(
    context: LAContext = LAContext(),
    authorizedAt: Date = Date(),
    expirationInterval: TimeInterval = 30.0
  ) -> BiometricAuthToken {
    BiometricAuthToken(
      context: context,
      authorizedAt: authorizedAt,
      expirationInterval: expirationInterval
    )
  }
}
