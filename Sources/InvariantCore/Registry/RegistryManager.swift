import CryptoKit
public import Foundation

/// Coordinates registry reading, writing, signature verification, and floor sync.
public struct RegistryManager: Sendable {
  public let environment: SystemEnvironment
  private let sshClient: SSHKeygenClient
  private let sudoClient: SudoClient

  public init(
    environment: SystemEnvironment = .standard,
    sshClient: SSHKeygenClient = SSHKeygenClient(),
    sudoClient: SudoClient = SudoClient()
  ) {
    self.environment = environment
    self.sshClient = sshClient
    self.sudoClient = sudoClient
  }

  public static func registryURL(repoRoot: URL) -> URL {
    repoRoot.appendingPathComponent("invariants/registry.lock")
  }

  public static func signatureURL(repoRoot: URL) -> URL {
    repoRoot.appendingPathComponent("invariants/registry.lock.sig")
  }

  public static func allowedSignersURL(repoRoot: URL) -> URL {
    repoRoot.appendingPathComponent("invariants/allowed_signers")
  }

  /// Loads, parses, and cryptographically verifies `registry.lock`.
  public func loadAndVerify(
    repoRoot: URL,
    installedEngineVersion: String = "1.0.0",
    identity: String = "owner"
  ) async throws(RegistryError) -> Registry {
    let lockURL = Self.registryURL(repoRoot: repoRoot)
    let sigURL = Self.signatureURL(repoRoot: repoRoot)
    let signersURL = Self.allowedSignersURL(repoRoot: repoRoot)

    guard FileManager.default.fileExists(atPath: lockURL.path) else {
      throw RegistryError.fileNotFound(lockURL)
    }
    guard FileManager.default.fileExists(atPath: sigURL.path) else {
      throw RegistryError.signatureNotFound(sigURL)
    }
    guard FileManager.default.fileExists(atPath: signersURL.path) else {
      throw RegistryError.signatureInvalid("Repository allowed_signers not found at \(signersURL.path)")
    }

    let lockData: Data
    do {
      lockData = try Data(contentsOf: lockURL)
    } catch {
      throw RegistryError.decodingFailed("Failed to read registry.lock: \(error.localizedDescription)")
    }

    let registry = try CanonicalJSON.parse(data: lockData)

    // Verify signers_hash binding if declared in registry.lock
    if let expectedSignersHash = registry.signersHash, !expectedSignersHash.isEmpty {
      let signersData: Data
      do {
        signersData = try Data(contentsOf: signersURL)
      } catch {
        throw RegistryError.signatureInvalid("Failed to read repository allowed_signers: \(error.localizedDescription)")
      }
      let actualHash = SHA256.hash(data: signersData).map { String(format: "%02x", $0) }.joined()
      guard actualHash == expectedSignersHash else {
        throw RegistryError.signatureInvalid(
          "Allowed signers hash mismatch: repository allowed_signers has been modified without re-signing."
        )
      }
    }

    // Verify cryptographic signature against in-repo allowed_signers
    let isValid: Bool
    do {
      isValid = try await sshClient.verify(
        allowedSignersURL: signersURL,
        identity: identity,
        namespace: "invariants",
        signatureURL: sigURL,
        fileURL: lockURL
      )
    } catch {
      throw RegistryError.signatureInvalid("Verification subprocess failed: \(error)")
    }

    guard isValid else {
      throw RegistryError.signatureInvalid("Signature in \(sigURL.path) is invalid for \(lockURL.path)")
    }

    // Check engine semver range
    if let currentSemver = Semver(string: installedEngineVersion) {
      let range = SemverRange(registry.engine)
      if !range.satisfies(currentSemver) {
        throw RegistryError.engineVersionMismatch(required: registry.engine, installed: installedEngineVersion)
      }
    }

    return registry
  }

  /// Writes registry in canonical JSON format, signs it, and records root floor.
  public func saveAndSign(
    registry: Registry,
    repoRoot: URL,
    keyURL: URL
  ) async throws(RegistryError) {
    let invariantsDir = repoRoot.appendingPathComponent("invariants")
    do {
      try FileManager.default.createDirectory(at: invariantsDir, withIntermediateDirectories: true)
    } catch {
      throw RegistryError.encodingFailed("Could not create invariants directory: \(error.localizedDescription)")
    }

    let signersURL = Self.allowedSignersURL(repoRoot: repoRoot)
    var updatedRegistry = registry
    if FileManager.default.fileExists(atPath: signersURL.path) {
      if let signersData = try? Data(contentsOf: signersURL) {
        let hash = SHA256.hash(data: signersData)
        updatedRegistry.signersHash = hash.map { String(format: "%02x", $0) }.joined()
      }
    }

    let lockURL = Self.registryURL(repoRoot: repoRoot)
    let canonicalContent = CanonicalJSON.serialize(updatedRegistry)
    guard let data = canonicalContent.data(using: .utf8) else {
      throw RegistryError.encodingFailed("Failed to encode canonical JSON as UTF-8")
    }

    do {
      try data.write(to: lockURL, options: .atomic)
    } catch {
      throw RegistryError.encodingFailed("Failed to write \(lockURL.path): \(error.localizedDescription)")
    }

    // Sign the file
    do {
      try await sshClient.sign(
        keyURL: keyURL,
        namespace: "invariants",
        fileURL: lockURL
      )
    } catch {
      throw RegistryError.signatureInvalid("Failed to sign registry.lock: \(error)")
    }

    // Update root floor
    do {
      try await sudoClient.writeFloor(
        repo: updatedRegistry.repo,
        version: updatedRegistry.version,
        environment: environment
      )
    } catch {
      throw RegistryError.signatureInvalid("Failed to write root floor for repo \(updatedRegistry.repo): \(error)")
    }
  }
}
