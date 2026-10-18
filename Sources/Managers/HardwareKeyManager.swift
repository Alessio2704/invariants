import Core
package import Foundation

/// Pure domain manager for Apple Secure Enclave hardware key lifecycle operations.
/// Completely headless: contains zero terminal prompts or CLI dependencies.
package enum HardwareKeyManager {
  package struct KeyInspectionResult: Sendable {
    package let keyURL: URL
    package let pubKey: String?
    package let keyType: String?
    package let fingerprint: String?
    package let backupCount: Int
    package let isAuthorizedInRepo: Bool

    package init(
      keyURL: URL,
      pubKey: String?,
      keyType: String?,
      fingerprint: String?,
      backupCount: Int,
      isAuthorizedInRepo: Bool
    ) {
      self.keyURL = keyURL
      self.pubKey = pubKey
      self.keyType = keyType
      self.fingerprint = fingerprint
      self.backupCount = backupCount
      self.isAuthorizedInRepo = isAuthorizedInRepo
    }
  }

  /// Generates a Touch ID protected P-256 key in Apple Secure Enclave.
  @discardableResult
  package static func generateHardwareKey(
    at destinationURL: URL = SystemEnvironment.defaultSigningKeyURL,
    force: Bool = false
  ) async throws -> URL {
    let defaultPub = destinationURL.appendingPathExtension("pub")

    if FileManager.default.fileExists(atPath: destinationURL.path) && !force {
      return destinationURL
    }

    let token = try await Authorizer.authorizeBiometrics(
      reason: "Touch your Touch ID sensor to enroll your hardware signing key in Apple Secure Enclave"
    )
    try SigningClient.generateSigningKey(at: destinationURL, token: token)

    guard FileManager.default.fileExists(atPath: defaultPub.path) else {
      throw KeyLifecycleError.publicKeyNotFound(defaultPub.path)
    }

    return destinationURL
  }

  /// Deletes local private signing key using Touch ID authorization.
  package static func deleteHardwareKey(
    at keyURL: URL = SystemEnvironment.defaultSigningKeyURL
  ) async throws {
    let token = try await Authorizer.authorizeBiometrics(
      reason: "Touch your Touch ID sensor to confirm deleting your Apple Secure Enclave signing key"
    )
    try SigningClient.deleteSigningKey(at: keyURL, token: token)
  }

  /// Rotates local hardware key, archiving old key with timestamp.
  package static func rotateHardwareKey(
    at keyURL: URL = SystemEnvironment.defaultSigningKeyURL
  ) async throws -> (archivedKeyURL: URL, newKeyURL: URL) {
    guard FileManager.default.fileExists(atPath: keyURL.path) else {
      throw KeyLifecycleError.keyNotFound(keyURL.path)
    }

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMddHHmmss"
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    let ts = formatter.string(from: Date())

    let baseName = keyURL.lastPathComponent
    let backupKey = keyURL.deletingLastPathComponent().appendingPathComponent("\(baseName).bak-\(ts)")
    let backupPub = backupKey.appendingPathExtension("pub")
    let oldPubURL = keyURL.appendingPathExtension("pub")

    try FileManager.default.moveItem(at: keyURL, to: backupKey)
    if FileManager.default.fileExists(atPath: oldPubURL.path) {
      try FileManager.default.moveItem(at: oldPubURL, to: backupPub)
    }

    let token = try await Authorizer.authorizeBiometrics(
      reason: "Touch your Touch ID sensor to enroll a new hardware signing key in Apple Secure Enclave"
    )
    try SigningClient.generateSigningKey(at: keyURL, token: token)

    return (archivedKeyURL: backupKey, newKeyURL: keyURL)
  }

  /// Removes archived rotation backup keys (.bak-*) from the given directory.
  package static func cleanBackups(
    in directory: URL = SystemEnvironment.defaultSigningKeyURL.deletingLastPathComponent()
  ) throws -> Int {
    guard let items = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
      return 0
    }
    let backups = items.filter { $0.hasPrefix(SystemPaths.keyBackupPrefix) }
    var deletedCount = 0
    for item in backups {
      let itemURL = directory.appendingPathComponent(item)
      if (try? FileManager.default.removeItem(at: itemURL)) != nil {
        deletedCount += 1
      }
    }
    return deletedCount
  }

  /// Inspects local signing identity and project enrollment.
  package static func inspectKey(
    at keyURL: URL = SystemEnvironment.defaultSigningKeyURL
  ) async -> KeyInspectionResult {
    let pubURL = keyURL.appendingPathExtension("pub")
    let pubKey = (try? String(contentsOf: pubURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)

    let keyType: String?
    if let pubKey {
      keyType = pubKey.contains("ecdsa-sha2-nistp256") ? "Apple Secure Enclave (Touch ID NIST P-256)" : "Software Key"
    } else {
      keyType = nil
    }

    let fingerprint = await SigningClient.fingerprint(pubKeyURL: pubURL)

    let sshDir = keyURL.deletingLastPathComponent()
    let items = (try? FileManager.default.contentsOfDirectory(atPath: sshDir.path)) ?? []
    let backupCount = items.filter { $0.hasPrefix(SystemPaths.keyBackupPrefix) && !$0.hasSuffix(".pub") }.count

    var isAuthorized: Bool = false
    if RepoLocator.hasCurrent, let pubKey {
      let signersURL = RegistryManager.allowedSignersURL()
      if let signersFile = try? AllowedSignersFile.read(from: signersURL) {
        isAuthorized = signersFile.entries.contains { $0.matches(keyString: pubKey) && $0.isActive() }
      }
    }

    return KeyInspectionResult(
      keyURL: keyURL,
      pubKey: pubKey,
      keyType: keyType,
      fingerprint: fingerprint,
      backupCount: backupCount,
      isAuthorizedInRepo: isAuthorized
    )
  }
}

package enum KeyLifecycleError: LocalizedError, Sendable {
  case keyNotFound(String)
  case publicKeyNotFound(String)

  package var errorDescription: String? {
    switch self {
    case .keyNotFound(let path):
      return "Signing key not found at \(path)."
    case .publicKeyNotFound(let path):
      return "Public key not found at \(path)."
    }
  }
}
