public import Foundation

/// Options for initializing invariants in a repository.
public struct InitOptions: Sendable {
  public var engineVersion: String
  public var defaultBranch: String
  public var projectConfig: ProjectConfig
  public var keyURL: URL

  public init(
    engineVersion: String = EngineVersion.current,
    defaultBranch: String = "main",
    projectConfig: ProjectConfig = ProjectConfig(),
    keyURL: URL
  ) {
    self.engineVersion = engineVersion
    self.defaultBranch = defaultBranch
    self.projectConfig = projectConfig
    self.keyURL = keyURL
  }
}

/// Service that initializes invariants structures, allowed signers, registry v1, and git commit.
public struct InitManager: Sendable {
  private let registryManager: RegistryManager
  private let gitClient: GitClient

  public init(
    registryManager: RegistryManager = RegistryManager(),
    gitClient: GitClient = GitClient()
  ) {
    self.registryManager = registryManager
    self.gitClient = gitClient
  }

  /// Initializes invariants in a repository: .gitignore, registry v1, in-repo allowed_signers, signature, and git commit.
  public func initialize(repoRootURL: URL, options: InitOptions) async throws {
    let fm = FileManager.default

    // 1. Update .gitignore
    let gitignoreURL = repoRootURL.appendingPathComponent(".gitignore")
    var gitignoreContent = (try? String(contentsOf: gitignoreURL, encoding: .utf8)) ?? ""
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
      engine: "^\(options.engineVersion)",
      defaultBranch: options.defaultBranch,
      project: options.projectConfig.isEmpty ? nil : options.projectConfig,
      rules: [:]
    )

    // 4. Write in-repo allowed_signers
    try Self.writeInitialAllowedSigners(keyURL: options.keyURL, repoRootURL: repoRootURL)

    // 5. Sign registry v1
    try await registryManager.saveAndSign(
      registry: registry,
      repoRoot: repoRootURL,
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

    try await gitClient.commit(
      repoRoot: repoRootURL,
      paths: paths,
      message: "Initialize invariants (v1)"
    )
  }

  /// Writes the public key from `keyURL` into `<repoRoot>/invariants/allowed_signers`.
  public static func writeInitialAllowedSigners(keyURL: URL, repoRootURL: URL) throws {
    let signersURL = RegistryManager.allowedSignersURL(repoRoot: repoRootURL)
    let pubURL = keyURL.pathExtension == "pub" ? keyURL : keyURL.appendingPathExtension("pub")
    func readTrimmed(at url: URL) -> String? {
      guard let str = try? String(contentsOf: url, encoding: .utf8) else { return nil }
      let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }

    guard let pubContent = readTrimmed(at: pubURL) ?? readTrimmed(at: keyURL) else {
      throw SystemError.fileIOError("Could not read public key from \(pubURL.path) or \(keyURL.path)")
    }

    var signersFile = try AllowedSignersFile.read(from: signersURL)
    try signersFile.addPublicKey(pubContent, principal: "*", namespaces: ["invariants"])
    try signersFile.write(to: signersURL)
  }
}
