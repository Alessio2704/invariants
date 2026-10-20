import CryptoKit
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

extension SigningClient {
  /// Generates an in-memory / software P-256 key pair for automated test suites.
  static func generateThrowawayKey(at keyURL: URL) throws(SystemError) {
    let parent = keyURL.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    } catch {
      throw SystemError.fileIOError("Failed to create directory \(parent.path): \(error.localizedDescription)")
    }

    let privateKey = P256.Signing.PrivateKey()
    do {
      try privateKey.rawRepresentation.write(to: keyURL, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    } catch {
      throw SystemError.fileIOError("Failed to write test key to \(keyURL.path): \(error.localizedDescription)")
    }

    let pubString = SSHSIG.formatOpenSSHPublicKey(privateKey.publicKey)
    let pubURL = keyURL.appendingPathExtension("pub")
    do {
      try pubString.write(to: pubURL, atomically: true, encoding: .utf8)
    } catch {
      throw SystemError.fileIOError("Failed to write public key to \(pubURL.path): \(error.localizedDescription)")
    }
  }
}
