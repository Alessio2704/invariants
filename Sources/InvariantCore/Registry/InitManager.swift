public import Foundation

/// Options for initializing invariants in a repository.
public struct InitOptions: Sendable {
  public var repoId: String
  public var engineVersion: String
  public var swiftIndexStore: String?
  public var tsconfigs: [String]
  public var keyURL: URL

  public init(
    repoId: String,
    engineVersion: String = "1.0.0",
    swiftIndexStore: String? = nil,
    tsconfigs: [String] = [],
    keyURL: URL
  ) {
    self.repoId = repoId
    self.engineVersion = engineVersion
    self.swiftIndexStore = swiftIndexStore
    self.tsconfigs = tsconfigs
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

    // 2. Configure project
    var projectConfig = ProjectConfig()
    if let idx = options.swiftIndexStore {
      projectConfig.swift = SwiftProjectConfig(indexStore: idx)
    }
    if !options.tsconfigs.isEmpty {
      projectConfig.ts = TSProjectConfig(tsconfig: options.tsconfigs)
    }

    // 3. Create Registry v1
    let registry = Registry(
      repo: options.repoId,
      version: 1,
      engine: "^\(options.engineVersion)",
      project: projectConfig.isEmpty ? nil : projectConfig,
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
    let parent = signersURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

    let pubURL = keyURL.pathExtension == "pub" ? keyURL : keyURL.appendingPathExtension("pub")
    func readTrimmed(at url: URL) -> String? {
      guard let str = try? String(contentsOf: url, encoding: .utf8) else { return nil }
      let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }

    guard let pubContent = readTrimmed(at: pubURL) ?? readTrimmed(at: keyURL) else {
      throw SystemError.fileIOError("Could not read public key from \(pubURL.path) or \(keyURL.path)")
    }

    let entry = "* namespaces=\"invariants\" \(pubContent)\n"
    try entry.write(to: signersURL, atomically: true, encoding: .utf8)
  }

  /// Discovers Swift Index store candidates in a repository.
  public static func discoverSwiftIndexCandidates(repoRootURL: URL) -> [String] {
    let fm = FileManager.default
    var candidates: [String] = []
    let rootPath = repoRootURL.path

    if let enumerator = fm.enumerator(
      at: repoRootURL,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) {
      while let fileURL = enumerator.nextObject() as? URL {
        let path = fileURL.path
        if path.contains("/node_modules/") || path.contains("/.build/") || path.contains("/invariants/.dev/") {
          enumerator.skipDescendants()
          continue
        }
        if path.hasSuffix("Index.noindex/DataStore") {
          var rel = String(path.dropFirst(rootPath.count))
          if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
          candidates.append(rel)
        }
      }
    }
    let spmStore = repoRootURL.appendingPathComponent(".build/debug/index/store")
    if fm.fileExists(atPath: spmStore.path) {
      candidates.append(".build/debug/index/store")
    }
    return Array(Set(candidates)).sorted()
  }

  /// Discovers tsconfig.json candidates in a repository.
  public static func discoverTsconfigCandidates(repoRootURL: URL) -> [String] {
    let fm = FileManager.default
    var candidates: [String] = []
    let rootPath = repoRootURL.path

    if let enumerator = fm.enumerator(
      at: repoRootURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) {
      while let fileURL = enumerator.nextObject() as? URL {
        let path = fileURL.path
        if path.contains("/node_modules/") || path.contains("/.build/") || path.contains("/invariants/.dev/") {
          enumerator.skipDescendants()
          continue
        }
        let fileName = fileURL.lastPathComponent
        if fileName.hasPrefix("tsconfig") && fileName.hasSuffix(".json") {
          var rel = String(path.dropFirst(rootPath.count))
          if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
          candidates.append(rel)
        }
      }
    }
    return candidates.sorted()
  }
}
