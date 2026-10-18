import Foundation
import LocalAuthentication

@testable import Core

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

extension ElevationToken {
  static func forTesting(
    authorizedAt: Date = Date(),
    expirationInterval: TimeInterval = 300.0
  ) -> ElevationToken {
    ElevationToken(
      authorizedAt: authorizedAt,
      expirationInterval: expirationInterval
    )
  }
}
