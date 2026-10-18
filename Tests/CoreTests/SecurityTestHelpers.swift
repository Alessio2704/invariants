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

extension Registry {
  static func forTesting(
    version: Int = 1,
    engine: String = "^1.0.0",
    defaultBranch: String = "main",
    languages: LanguagesConfig = {
      var config = LanguagesConfig()
      config[SwiftLanguage.self] = SwiftLanguage.Config(indexStore: "build/Index.noindex/DataStore")
      return config
    }(),
    rules: [String: String] = [:],
    signersHash: String? = nil
  ) -> Registry {
    Registry(
      version: version,
      engine: engine,
      defaultBranch: defaultBranch,
      languages: languages,
      rules: rules,
      signersHash: signersHash
    )
  }
}
