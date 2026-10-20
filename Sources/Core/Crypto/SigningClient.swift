import CryptoKit
public import Foundation
import LocalAuthentication
import Security

/// Cryptographic signing and verification client combining Apple CryptoKit / Secure Enclave with OpenSSH allowed_signers verification.
public enum SigningClient: Sendable {
  /// Deletes a local private signing key and its corresponding public key from this machine.
  /// Strictly requires a valid BiometricAuthToken issued by Authorizer.
  public static func deleteSigningKey(
    at keyURL: URL,
    token: BiometricAuthToken
  ) throws(SystemError) {
    try token.validateFreshness()

    let pubURL = keyURL.appendingPathExtension("pub")
    guard FileManager.default.fileExists(atPath: keyURL.path) || FileManager.default.fileExists(atPath: pubURL.path)
    else {
      return
    }

    do {
      if FileManager.default.fileExists(atPath: keyURL.path) {
        try FileManager.default.removeItem(at: keyURL)
      }
      if FileManager.default.fileExists(atPath: pubURL.path) {
        try FileManager.default.removeItem(at: pubURL)
      }
    } catch {
      throw SystemError.fileIOError("Failed to delete signing key at \(keyURL.path): \(error.localizedDescription)")
    }
  }

  /// Generates a hardware-bound P-256 signing key in the Apple Secure Enclave.
  /// Strictly requires Apple Secure Enclave hardware with a valid BiometricAuthToken.
  /// Zero fallback.
  public static func generateSigningKey(
    at keyURL: URL,
    token: BiometricAuthToken
  ) throws(SystemError) {
    try token.validateFreshness()

    guard SecureEnclave.isAvailable else {
      throw SystemError.secureEnclaveUnavailable(
        "Apple Secure Enclave hardware is not available on this machine. Secure hardware keys cannot be created."
      )
    }

    let parent = keyURL.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    } catch {
      throw SystemError.fileIOError("Failed to create directory \(parent.path): \(error.localizedDescription)")
    }

    var error: Unmanaged<CFError>?
    guard
      let accessControl = SecAccessControlCreateWithFlags(
        nil,
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        [.privateKeyUsage, .userPresence],
        &error
      )
    else {
      let desc = error?.takeRetainedValue().localizedDescription ?? "unknown error"
      throw SystemError.cryptographicError("Failed to configure Secure Enclave access control: \(desc)")
    }

    let privateKey: SecureEnclave.P256.Signing.PrivateKey
    do {
      privateKey = try SecureEnclave.P256.Signing.PrivateKey(
        accessControl: accessControl,
        authenticationContext: token.context
      )
    } catch {
      throw SystemError.cryptographicError(
        "Failed to generate Secure Enclave private key: \(error.localizedDescription)")
    }

    let tokenData = privateKey.dataRepresentation
    do {
      try tokenData.write(to: keyURL, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    } catch {
      throw SystemError.fileIOError(
        "Failed to write private key token to \(keyURL.path): \(error.localizedDescription)")
    }

    let pubString = SSHSIG.formatOpenSSHPublicKey(privateKey.publicKey)
    let pubURL = keyURL.appendingPathExtension("pub")
    do {
      try pubString.write(to: pubURL, atomically: true, encoding: .utf8)
    } catch {
      throw SystemError.fileIOError("Failed to write public key to \(pubURL.path): \(error.localizedDescription)")
    }
  }

  /// Signs a file using the private key at `keyURL` (Secure Enclave or software P-256 test key).
  /// Produces `<fileURL>.sig` in OpenSSH PROTOCOL.sshsig format.
  public static func sign(
    keyURL: URL,
    namespace: String = "invariants",
    fileURL: URL
  ) async throws(SystemError) {
    let sigURL = fileURL.appendingPathExtension("sig")
    try? FileManager.default.removeItem(at: sigURL)

    let keyData: Data
    do {
      keyData = try Data(contentsOf: keyURL)
    } catch {
      throw SystemError.fileIOError("Failed to read private key at \(keyURL.path): \(error.localizedDescription)")
    }

    let fileData: Data
    do {
      fileData = try Data(contentsOf: fileURL)
    } catch {
      throw SystemError.fileIOError("Failed to read file for signing at \(fileURL.path): \(error.localizedDescription)")
    }

    // 1. Check if software P-256 test key (raw 32 bytes)
    if keyData.count == 32, let softKey = try? P256.Signing.PrivateKey(rawRepresentation: keyData) {
      let signedData = SSHSIG.buildSignedData(messageData: fileData, namespace: namespace)
      let sig: P256.Signing.ECDSASignature
      do {
        sig = try softKey.signature(for: signedData)
      } catch {
        throw SystemError.cryptographicError("Failed to create software P-256 signature: \(error.localizedDescription)")
      }

      let armored = SSHSIG.buildArmoredSignature(
        rawSignature: sig.rawRepresentation,
        publicKey: softKey.publicKey,
        namespace: namespace
      )
      do {
        try armored.write(to: sigURL, atomically: true, encoding: .utf8)
      } catch {
        throw SystemError.fileIOError("Failed to write signature to \(sigURL.path): \(error.localizedDescription)")
      }
      return
    }

    // 2. Apple Secure Enclave P-256 signing (triggers Touch ID prompt)
    guard SecureEnclave.isAvailable else {
      throw SystemError.secureEnclaveUnavailable(
        "Apple Secure Enclave hardware is not available on this machine to authorize signature."
      )
    }

    let authContext = LAContext()
    authContext.localizedReason = "Authorize Invariants to sign rule manifest"

    let seKey: SecureEnclave.P256.Signing.PrivateKey
    do {
      seKey = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: keyData, authenticationContext: authContext)
    } catch {
      throw SystemError.cryptographicError(
        "Failed to load Secure Enclave key from \(keyURL.path): \(error.localizedDescription)"
      )
    }

    let signedData = SSHSIG.buildSignedData(messageData: fileData, namespace: namespace)
    let sig: P256.Signing.ECDSASignature
    do {
      sig = try seKey.signature(for: signedData)
    } catch {
      throw SystemError.cryptographicError(
        "Secure Enclave biometric authorization failed: \(error.localizedDescription)")
    }

    let armored = SSHSIG.buildArmoredSignature(
      rawSignature: sig.rawRepresentation,
      publicKey: seKey.publicKey,
      namespace: namespace
    )
    do {
      try armored.write(to: sigURL, atomically: true, encoding: .utf8)
    } catch {
      throw SystemError.fileIOError("Failed to write signature to \(sigURL.path): \(error.localizedDescription)")
    }
  }

  /// Verifies a file signature using `ssh-keygen -Y verify -f <allowedSigners> -I <identity> -n <namespace> -s <sigFile> < <file>`.
  public static func verify(
    allowedSignersURL: URL,
    identity: String = "owner",
    namespace: String = "invariants",
    signatureURL: URL,
    fileURL: URL
  ) async throws(SystemError) -> Bool {
    guard FileManager.default.fileExists(atPath: allowedSignersURL.path) else {
      return false
    }
    guard FileManager.default.fileExists(atPath: signatureURL.path) else {
      return false
    }
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return false
    }

    let fileData: Data
    do {
      fileData = try Data(contentsOf: fileURL)
    } catch {
      throw SystemError.fileIOError("Failed to read file for verification: \(error.localizedDescription)")
    }

    let output = try await SubprocessRunner.run(
      binary: .sshKeygen,
      arguments: [
        "-Y", "verify",
        "-f", allowedSignersURL.path,
        "-I", identity,
        "-n", namespace,
        "-s", signatureURL.path,
      ],
      stdinData: fileData
    )
    return output.exitCode == 0
  }

  /// Calculates the SHA-256 fingerprint of a public key file.
  public static func fingerprint(pubKeyURL: URL) throws(SystemError) -> String {
    let trimmed: String
    do {
      trimmed = try pubKeyURL.readTrimmedUTF8()
    } catch {
      throw SystemError.fileIOError("Failed to read public key at \(pubKeyURL.path): \(error.localizedDescription)")
    }
    guard let entry = AllowedSignerEntry.parse(line: "* \(trimmed)"),
      let keyBytes = Data(base64Encoded: entry.keyData)
    else {
      throw SystemError.cryptographicError("Invalid public key format in \(pubKeyURL.path)")
    }
    let hash = SHA256.hash(data: keyBytes)
    var b64 = Data(hash).base64EncodedString()
    while b64.hasSuffix("=") { b64.removeLast() }
    return "SHA256:\(b64)"
  }
}
