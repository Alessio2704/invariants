public import Foundation

/// Error produced when resolving or authorizing a cryptographic signing session.
public enum SigningError: LocalizedError, Equatable, Sendable {
  case keyNotFound(String)
  case publicKeyMissing(String)
  case unauthorizedSigner(publicKey: String, allowedSignersPath: String)

  public var errorDescription: String? {
    switch self {
    case .keyNotFound(let path):
      return """
        Signing key not found at \(path).
        Run 'invariants key generate' or specify a valid key with --key <path>.
        """
    case .publicKeyMissing(let path):
      return """
        Public key file not found at \(path).
        A corresponding .pub file must exist next to your private key.
        """
    case .unauthorizedSigner(let key, let path):
      return """
        Signing key is not authorized in \(path).
        Public key: \(key)
        Ask a repository administrator to add your key with 'invariants signers add'.
        """
    }
  }
}

/// An authorized cryptographic signing session for repository mutations.
/// Validates private key presence, public key existence, and repository authorization upfront (fail-fast).
public struct SigningSession: Sendable, Equatable {
  public let privateKeyURL: URL
  public let publicKey: String
  public let publicKeyURL: URL

  public init(
    privateKeyURL: URL,
    publicKey: String,
    publicKeyURL: URL
  ) {
    self.privateKeyURL = privateKeyURL
    self.publicKey = publicKey
    self.publicKeyURL = publicKeyURL
  }

  /// Resolves the signing key and authorizes the session against the repository's `invariants/allowed_signers`.
  public static func authorize(
    customPath: String? = nil,
    in repoRoot: URL? = nil,
    skipAllowedSignersCheck: Bool = false,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws(SigningError) -> Self {
    let privateKeyURL = try SigningKeyResolver.resolveKey(
      customPath: customPath,
      environment: environment
    )

    let pubURL = privateKeyURL.appendingPathExtension("pub")
    guard FileManager.default.fileExists(atPath: pubURL.path),
      let pubContent = try? pubURL.readTrimmedUTF8(),
      !pubContent.isEmpty
    else {
      throw SigningError.publicKeyMissing(pubURL.path)
    }

    if !skipAllowedSignersCheck {
      let targetRepo = repoRoot ?? RepoLocator.current
      let signersURL = targetRepo.appendingPathComponent("invariants/allowed_signers")
      guard let signersFile = try? AllowedSignersFile.read(from: signersURL) else {
        throw SigningError.unauthorizedSigner(publicKey: pubContent, allowedSignersPath: signersURL.path)
      }
      let isAuthorized = signersFile.entries.contains { $0.matches(keyString: pubContent) && $0.isActive() }
      guard isAuthorized else {
        throw SigningError.unauthorizedSigner(publicKey: pubContent, allowedSignersPath: signersURL.path)
      }
    }

    return Self(
      privateKeyURL: privateKeyURL,
      publicKey: pubContent,
      publicKeyURL: pubURL
    )
  }
}
