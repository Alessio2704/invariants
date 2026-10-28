import Core
package import Foundation
import Managers
import Terminal

/// Interactive CLI workflow orchestrating repository signer management.
package enum SignersWorkflow {
  package static func list() throws {
    let signersURL = RegistryManager.allowedSignersURL()
    guard FileManager.default.fileExists(atPath: signersURL.path) else {
      Terminal.info("No invariants/allowed_signers file found at \(signersURL.path).")
      return
    }

    let entries = try SignersManager.loadSigners(at: signersURL)
    if entries.isEmpty {
      Terminal.info("invariants/allowed_signers at \(signersURL.path) is empty.")
      return
    }

    Terminal.header("Trusted Invariant Signers (\(signersURL.path)):")
    for (index, entry) in entries.enumerated() {
      let status = entry.isActive() ? "Active" : "Discontinued / Expired"
      Terminal.numbered(index + 1, text: "[\(status)] \(entry.serialize())")
    }
  }

  package static func add(
    key: String,
    identity: String?,
    signingKey: String?
  ) async throws {
    // 1. Authorize signing session upfront (fail-fast before mutating allowed_signers)
    let session = try SigningSession.authorize(customPath: signingKey)

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

    let keyWithComment: String
    if let identity, !identity.isEmpty, !keyContent.contains(identity) {
      keyWithComment = "\(keyContent) \(identity)"
    } else {
      keyWithComment = keyContent
    }

    let assignedPrincipal: String
    if let identity, !identity.isEmpty {
      assignedPrincipal = identity
    } else {
      assignedPrincipal = "*"
    }
    try SignersManager.addSigner(
      keyContent: keyWithComment,
      principal: assignedPrincipal,
      at: signersURL
    )

    let newVersion = try await SignersManager.bumpAndSignRegistry(keyURL: session.privateKeyURL)
    try await GitClient.commit(
      paths: [
        "invariants/allowed_signers",
        "invariants/registry.lock",
        "invariants/registry.lock.sig",
      ],
      message: "Add invariant signer (registry v\(newVersion))"
    )
    Terminal.success("Added signer to \(signersURL.path) and committed updated registry v\(newVersion).")
  }

  package static func revoke(
    pattern: String,
    hard: Bool,
    signingKey: String?
  ) async throws {
    // 1. Authorize signing session upfront (fail-fast before mutating allowed_signers)
    let session = try SigningSession.authorize(customPath: signingKey)

    let signersURL = RegistryManager.allowedSignersURL()
    let matchedCount = try SignersManager.revokeSigner(
      matching: pattern,
      hard: hard,
      at: signersURL
    )

    guard matchedCount > 0 else {
      Terminal.info("No signers matched pattern '\(pattern)'.")
      return
    }

    let newVersion = try await SignersManager.bumpAndSignRegistry(keyURL: session.privateKeyURL)
    try await GitClient.commit(
      paths: [
        "invariants/allowed_signers",
        "invariants/registry.lock",
        "invariants/registry.lock.sig",
      ],
      message: "Revoke invariant signer '\(pattern)' (registry v\(newVersion))"
    )
    let mode = hard ? "Hard revoked (purged)" : "Soft revoked (valid-before set)"
    let revMsg =
      "\(mode) \(matchedCount) signer(s) matching '\(pattern)' and committed updated registry v\(newVersion)."
    Terminal.success(revMsg)
  }

  package static func rotate(
    old: String?,
    new: String?,
    sunset: TimeInterval = 86400,
    signingKey: String?
  ) async throws {
    let signersURL = RegistryManager.allowedSignersURL()
    let currentEntries = try SignersManager.loadSigners(at: signersURL)

    let keyDir: URL
    if let signingKey {
      keyDir = URL(fileURLWithPath: (signingKey as NSString).expandingTildeInPath).deletingLastPathComponent()
    } else {
      keyDir = SystemEnvironment.defaultSigningKeyURL.deletingLastPathComponent()
    }

    // 1. Authorize signing session upfront (fail-fast before mutating allowed_signers)
    // DRIFT-03a: If the signingKey was just rotated and not yet enrolled, check for an active backup key
    let session: SigningSession
    do {
      session = try SigningSession.authorize(customPath: signingKey)
    } catch let error {
      if let (_, backupKeyURL) = SignersManager.detectOldBackupKey(matching: currentEntries, in: keyDir) {
        session = try SigningSession.authorize(customPath: backupKeyURL.path)
      } else {
        throw error
      }
    }

    // 2. Resolve new public key content
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

    // 3. Resolve old public key or pattern
    let oldKeyPattern: String
    if let old {
      let expanded = (old as NSString).expandingTildeInPath
      if FileManager.default.fileExists(atPath: expanded) {
        oldKeyPattern = try URL(fileURLWithPath: expanded).readTrimmedUTF8()
      } else {
        oldKeyPattern = old.trimmed
      }
    } else {
      guard let (detectedOldKey, _) = SignersManager.detectOldBackupKey(matching: currentEntries, in: keyDir) else {
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

    let newVersion = try await SignersManager.bumpAndSignRegistry(keyURL: session.privateKeyURL)
    try await GitClient.commit(
      paths: [
        "invariants/allowed_signers",
        "invariants/registry.lock",
        "invariants/registry.lock.sig",
      ],
      message: "Rotate invariant signer (registry v\(newVersion))"
    )
    let rotMsg =
      "Rotated signer in \(signersURL.path) (sunset: \(Int(sunset))s) and committed updated registry v\(newVersion)."
    Terminal.success(rotMsg)
  }

  private static func isValidSSHKey(_ key: String) -> Bool {
    key.hasPrefix("ssh-") || key.hasPrefix("ecdsa-") || key.hasPrefix("sk-")
  }
}
