package import Core
package import Foundation

/// Pure domain manager for repository signer management and registry signing transactions.
/// Headless: contains zero terminal prints or CLI dependencies.
package enum SignersManager {
  /// Reads and returns all entries from the repository's allowed_signers file.
  package static func loadSigners(
    at signersURL: URL? = nil
  ) throws -> [AllowedSignerEntry] {
    let targetURL = signersURL ?? RegistryManager.allowedSignersURL()
    guard FileManager.default.fileExists(atPath: targetURL.path) else {
      throw SystemError.fileIOError("invariants/allowed_signers not found at \(targetURL.path)")
    }
    let signersFile = try AllowedSignersFile.read(from: targetURL)
    return signersFile.entries
  }

  /// Adds a public key to the repository's allowed_signers file.
  package static func addSigner(
    keyContent: String,
    principal: String = "*",
    namespaces: [String] = ["invariants"],
    at signersURL: URL? = nil
  ) throws {
    let targetURL = signersURL ?? RegistryManager.allowedSignersURL()
    guard FileManager.default.fileExists(atPath: targetURL.path) else {
      throw SystemError.fileIOError("invariants/allowed_signers not found at \(targetURL.path)")
    }
    var signersFile = try AllowedSignersFile.read(from: targetURL)
    try signersFile.addPublicKey(keyContent, principal: principal, namespaces: namespaces)
    try signersFile.write(to: targetURL)
  }

  /// Revokes signers matching the given pattern (soft revocation sets validBefore, hard purges).
  @discardableResult
  package static func revokeSigner(
    matching pattern: String,
    hard: Bool = false,
    effectiveDate: Date = Date(),
    at signersURL: URL? = nil
  ) throws -> Int {
    let targetURL = signersURL ?? RegistryManager.allowedSignersURL()
    guard FileManager.default.fileExists(atPath: targetURL.path) else {
      throw SystemError.fileIOError("invariants/allowed_signers not found at \(targetURL.path)")
    }
    var signersFile = try AllowedSignersFile.read(from: targetURL)
    let matchedCount: Int

    if hard {
      let initialCount = signersFile.entries.count
      signersFile.entries.removeAll {
        $0.matches(keyString: pattern) || $0.principals.contains(pattern) || $0.comment?.contains(pattern) == true
      }
      matchedCount = initialCount - signersFile.entries.count
    } else {
      matchedCount = signersFile.revoke(keyDataOrSubstring: pattern, effectiveDate: effectiveDate)
    }

    if matchedCount > 0 {
      try signersFile.write(to: targetURL)
    }
    return matchedCount
  }

  /// Rotates an existing signer key with a sunset grace period and enrolls the new key.
  package static func rotateSigner(
    oldKeyDataOrSubstring: String,
    newPublicKeyString: String,
    sunsetDuration: TimeInterval = 86400,
    now: Date = Date(),
    at signersURL: URL? = nil
  ) throws {
    let targetURL = signersURL ?? RegistryManager.allowedSignersURL()
    guard FileManager.default.fileExists(atPath: targetURL.path) else {
      throw SystemError.fileIOError("invariants/allowed_signers not found at \(targetURL.path)")
    }
    var signersFile = try AllowedSignersFile.read(from: targetURL)
    try signersFile.rotate(
      oldKeyDataOrSubstring: oldKeyDataOrSubstring,
      newPublicKeyString: newPublicKeyString,
      sunsetDuration: sunsetDuration,
      now: now
    )
    try signersFile.write(to: targetURL)
  }

  /// Automatically discovers the most recent archived rotation backup key from ~/.ssh/ matching an active signer.
  package static func detectOldBackupKey(
    matching signers: [AllowedSignerEntry],
    in directory: URL = SystemEnvironment.defaultSigningKeyURL.deletingLastPathComponent()
  ) -> (keyContent: String, privateKeyURL: URL)? {
    guard let items = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
      return nil
    }
    let backupPubs = items.filter {
      $0.contains(".bak-") && $0.hasSuffix(".pub")
    }.sorted(by: >)

    for backupFile in backupPubs {
      let backupPubURL = directory.appendingPathComponent(backupFile)
      let backupKeyURL = directory.appendingPathComponent(String(backupFile.dropLast(4)))
      guard FileManager.default.fileExists(atPath: backupKeyURL.path),
        let content = try? backupPubURL.readTrimmedUTF8(), !content.isEmpty
      else {
        continue
      }
      if signers.contains(where: { $0.matches(keyString: content) && $0.isActive() }) {
        return (content, backupKeyURL)
      }
    }
    return nil
  }

  /// Increments registry version and signs with the given signing key.
  @discardableResult
  package static func bumpAndSignRegistry(
    keyURL: URL,
    at lockURL: URL? = nil
  ) async throws -> Int {
    let targetURL = lockURL ?? RegistryManager.registryURL()
    guard FileManager.default.fileExists(atPath: targetURL.path) else {
      throw SystemError.fileIOError("registry.lock not found at \(targetURL.path)")
    }
    let data = try Data(contentsOf: targetURL)
    var registry = try CanonicalJSON.parse(data: data)
    registry.version += 1
    try await RegistryManager.saveAndSign(registry: registry, keyURL: keyURL)
    return registry.version
  }
}
