public import Core
public import Foundation

/// Options for initializing invariants in a repository.
public struct InitOptions: Sendable {
  public var engine: String
  public var defaultBranch: String
  public var languages: LanguagesConfig
  public var keyURL: URL

  public init(
    engine: String = EngineVersion.defaultRange,
    defaultBranch: String = "main",
    languages: LanguagesConfig,
    keyURL: URL
  ) {
    self.engine = engine
    self.defaultBranch = defaultBranch
    self.languages = languages
    self.keyURL = keyURL
  }
}

/// Service that initializes invariants structures, allowed signers, registry v1, and git commit.
public enum InitManager: Sendable {
  /// Initializes invariants in a repository: .gitignore, registry v1, in-repo allowed_signers, signature, and git commit.
  public static func initialize(options: InitOptions) async throws {
    let repoRootURL = RepoLocator.current
    let fm = FileManager.default

    // 1. Update .gitignore
    let gitignoreURL = repoRootURL.appendingPathComponent(".gitignore")
    var gitignoreContent = ""
    if fm.fileExists(atPath: gitignoreURL.path) {
      gitignoreContent = try gitignoreURL.readUTF8()
    }
    if !gitignoreContent.contains("invariants/.dev/") {
      if !gitignoreContent.isEmpty && !gitignoreContent.hasSuffix("\n") {
        gitignoreContent.append("\n")
      }
      gitignoreContent.append("\n# Invariants dev workspace\ninvariants/.dev/\n")
      try gitignoreContent.data(using: .utf8)?.write(to: gitignoreURL, options: .atomic)
    }

    // 2. Create Registry v1
    let registry = Registry(
      version: 1,
      engine: options.engine,
      defaultBranch: options.defaultBranch,
      languages: options.languages,
      rules: [:]
    )

    // 4. Write in-repo allowed_signers
    try Self.writeInitialAllowedSigners(keyURL: options.keyURL)

    // 5. Sign registry v1
    try await RegistryManager.saveAndSign(
      registry: registry,
      keyURL: options.keyURL
    )

    // 6. Commit setup
    var paths = [
      "invariants/allowed_signers",
      "invariants/registry.lock",
      "invariants/registry.lock.sig",
    ]
    if fm.fileExists(atPath: gitignoreURL.path) {
      paths.append(".gitignore")
    }

    try await GitClient.commit(
      paths: paths,
      message: "Initialize invariants (v1)"
    )
  }

  /// Writes the public key from `keyURL` into `<repoRoot>/invariants/allowed_signers`.
  public static func writeInitialAllowedSigners(keyURL: URL) throws {
    let fm = FileManager.default
    let signersURL = RegistryManager.allowedSignersURL()
    let pubURL = keyURL.pathExtension == "pub" ? keyURL : keyURL.appendingPathExtension("pub")

    let pubContent: String
    if fm.fileExists(atPath: pubURL.path) {
      pubContent = try pubURL.readTrimmedUTF8()
    } else if fm.fileExists(atPath: keyURL.path) {
      pubContent = try keyURL.readTrimmedUTF8()
    } else {
      throw SystemError.fileIOError("Could not find public key at \(pubURL.path) or \(keyURL.path)")
    }

    var signersFile = AllowedSignersFile()
    try signersFile.addPublicKey(pubContent, principal: "*", namespaces: ["invariants"])
    try signersFile.write(to: signersURL)
  }
}
