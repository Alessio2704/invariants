import Core
package import Foundation
import Managers

/// Interactive CLI workflow orchestrating repository signer management.
package enum SignersWorkflow {
  package static func list() throws {
    let signersURL = RegistryManager.allowedSignersURL()
    guard FileManager.default.fileExists(atPath: signersURL.path) else {
      print("No invariants/allowed_signers file found at \(signersURL.path).")
      return
    }

    let entries = try SignersManager.loadSigners(at: signersURL)
    if entries.isEmpty {
      print("invariants/allowed_signers at \(signersURL.path) is empty.")
      return
    }

    print("Trusted Invariant Signers (\(signersURL.path)):")
    print("──────────────────────────────────────────────────")
    for (index, entry) in entries.enumerated() {
      let status = entry.isActive() ? "Active" : "Discontinued / Expired"
      print("[\(index + 1)] [\(status)] \(entry.serialize())")
    }
  }

  package static func add(
    key: String,
    identity: String?,
    signingKey: String?
  ) async throws {
    let signersURL = RegistryManager.allowedSignersURL()
    let keyContent: String
    let expanded = (key as NSString).expandingTildeInPath
    if FileManager.default.fileExists(atPath: expanded) {
      keyContent = try URL(fileURLWithPath: expanded).readTrimmedUTF8()
    } else {
      keyContent = key.trimmed
    }

    guard isValidSSHKey(keyContent) else {
      throw SystemError.fileIOError("Invalid SSH public key format. Must start with 'ssh-', 'ecdsa-', or 'sk-'.")
    }

    let principal = identity ?? "*"
    try SignersManager.addSigner(
      keyContent: keyContent,
      principal: principal,
      at: signersURL
    )

    let keyURL = try await resolveSigningKey(customPath: signingKey)
    try await SignersManager.bumpAndSignRegistry(keyURL: keyURL)
    print("✓ Added signer to \(signersURL.path) and signed updated registry.")
  }

  package static func revoke(
    pattern: String,
    hard: Bool,
    signingKey: String?
  ) async throws {
    let signersURL = RegistryManager.allowedSignersURL()
    let matchedCount = try SignersManager.revokeSigner(
      matching: pattern,
      hard: hard,
      at: signersURL
    )

    guard matchedCount > 0 else {
      print("No signers matched pattern '\(pattern)'.")
      return
    }

    let keyURL = try await resolveSigningKey(customPath: signingKey)
    try await SignersManager.bumpAndSignRegistry(keyURL: keyURL)
    let mode = hard ? "Hard revoked (purged)" : "Soft revoked (valid-before set)"
    print("✓ \(mode) \(matchedCount) signer(s) matching '\(pattern)' and signed updated registry.")
  }

  package static func rotate(
    old: String?,
    new: String?,
    sunset: TimeInterval = 86400,
    signingKey: String?
  ) async throws {
    let signersURL = RegistryManager.allowedSignersURL()
    let currentEntries = try SignersManager.loadSigners(at: signersURL)

    // 1. Resolve new public key content
    let newKeyContent: String
    if let new {
      let expanded = (new as NSString).expandingTildeInPath
      if FileManager.default.fileExists(atPath: expanded) {
        newKeyContent = try URL(fileURLWithPath: expanded).readTrimmedUTF8()
      } else {
        newKeyContent = new.trimmed
      }
    } else {
      let defaultPub = SystemEnvironment.defaultSigningKeyURL.appendingPathExtension("pub")
      guard FileManager.default.fileExists(atPath: defaultPub.path) else {
        throw SystemError.fileIOError(
          "No new public key provided and \(defaultPub.path) not found. Specify --new <key-or-file>."
        )
      }
      newKeyContent = try defaultPub.readTrimmedUTF8()
    }

    guard isValidSSHKey(newKeyContent) else {
      throw SystemError.fileIOError("Invalid new SSH public key format. Must start with 'ssh-', 'ecdsa-', or 'sk-'.")
    }

    // 2. Resolve old public key or pattern
    let oldKeyPattern: String
    if let old {
      let expanded = (old as NSString).expandingTildeInPath
      if FileManager.default.fileExists(atPath: expanded) {
        oldKeyPattern = try URL(fileURLWithPath: expanded).readTrimmedUTF8()
      } else {
        oldKeyPattern = old.trimmed
      }
    } else {
      guard let detectedOldKey = SignersManager.detectOldBackupKey(matching: currentEntries) else {
        throw SystemError.fileIOError(
          "Could not detect old key from ~/.ssh/ backups. Please specify --old <pattern-or-key>."
        )
      }
      oldKeyPattern = detectedOldKey
    }

    try SignersManager.rotateSigner(
      oldKeyDataOrSubstring: oldKeyPattern,
      newPublicKeyString: newKeyContent,
      sunsetDuration: sunset,
      at: signersURL
    )

    let keyURL = try await resolveSigningKey(customPath: signingKey)
    try await SignersManager.bumpAndSignRegistry(keyURL: keyURL)
    print("✓ Rotated signer in \(signersURL.path) (sunset: \(Int(sunset))s) and signed updated registry.")
  }

  private static func resolveSigningKey(customPath: String?) async throws -> URL {
    guard let keyURL = await SigningKeyWorkflow.resolveOrPrompt(customPath: customPath) else {
      throw SystemError.fileIOError("No Invariants signing key resolved to sign registry update.")
    }
    return keyURL
  }

  private static func isValidSSHKey(_ key: String) -> Bool {
    key.hasPrefix("ssh-") || key.hasPrefix("ecdsa-") || key.hasPrefix("sk-")
  }
}
