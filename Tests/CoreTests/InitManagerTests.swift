import Foundation
import Testing

@testable import Core
@testable import Managers

@Suite("InitManager Repository Initialization Tests", .tags(.unit))
struct InitManagerTests {
  @Test(
    "Initializes clean repository with registry v1, allowed_signers, gitignore, and commit without touching git hooks")
  func initializeCleanRepository() async throws {
    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory.appendingPathComponent("init_test_\(UUID().uuidString)")
    let repoURL = tmpDir.appendingPathComponent("test-project")
    let keyURL = tmpDir.appendingPathComponent("id_p256")

    try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    // Setup git repo
    _ = try await SubprocessRunner.run(
      binary: .git, arguments: ["-C", repoURL.path, "init", "-b", "main"])
    _ = try await SubprocessRunner.run(
      binary: .git, arguments: ["-C", repoURL.path, "config", "user.name", "Init Tester"])
    _ = try await SubprocessRunner.run(
      binary: .git,
      arguments: ["-C", repoURL.path, "config", "user.email", "tester@invariants.local"])

    // Generate throwaway key
    try SigningClient.generateThrowawayKey(at: keyURL)

    var ast = ASTConfig()
    ast[SwiftLanguage.self] = ["main": SwiftLanguage.Config(indexStore: "build/Index.noindex/DataStore")]
    ast[TypeScriptLanguage.self] = ["main": TypeScriptLanguage.Config(tsconfig: "tsconfig.json")]

    let options = InitOptions(
      engine: "^1.0.0",
      languages: [.swift, .ts],
      ast: ast,
      keyURL: keyURL
    )

    try await RepoLocator.withRepoRoot(repoURL) {
      try await InitManager.initialize(options: options)

      // 1. Verify in-repo allowed_signers
      let signersURL = RegistryManager.allowedSignersURL()
      #expect(fm.fileExists(atPath: signersURL.path))
      let signersContent = try signersURL.readUTF8()
      let pubKey = try keyURL.appendingPathExtension("pub").readTrimmedUTF8()
      #expect(signersContent.contains(pubKey))
      #expect(signersContent.contains("namespaces=\"invariants\""))

      // 2. Verify registry.lock and registry.lock.sig
      let lockURL = RegistryManager.registryURL()
      let sigURL = RegistryManager.signatureURL()
      #expect(fm.fileExists(atPath: lockURL.path))
      #expect(fm.fileExists(atPath: sigURL.path))

      // 3. Verify registry can be loaded and cryptographically verified
      let loaded = try await RegistryManager.loadAndVerify()
      #expect(loaded.version == 1)
      #expect(loaded.defaultBranch == "main")
      #expect(loaded.languages == [.swift, .ts])
      #expect(loaded.ast[SwiftLanguage.self]["main"]?.indexStore == "build/Index.noindex/DataStore")
      #expect(loaded.ast[TypeScriptLanguage.self]["main"]?.tsconfig == "tsconfig.json")
    }

    // 4. Verify .gitignore updated with invariants/.dev/
    let gitignoreURL = repoURL.appendingPathComponent(".gitignore")
    #expect(fm.fileExists(atPath: gitignoreURL.path))
    let gitignoreContent = try gitignoreURL.readUTF8()
    #expect(gitignoreContent.contains("invariants/.dev/"))

    // 5. Verify NO git hooks hijacked
    let githooksDir = repoURL.appendingPathComponent(".githooks")
    #expect(!fm.fileExists(atPath: githooksDir.path))
    let hooksCheck = try await SubprocessRunner.run(
      binary: .git,
      arguments: ["-C", repoURL.path, "config", "--get", "core.hooksPath"]
    )
    #expect(hooksCheck.exitCode != 0 || hooksCheck.trimmedStdout.isEmpty)

    // 6. Verify git commit exists with initial commit
    let logOutput = try await SubprocessRunner.run(
      binary: .git,
      arguments: ["-C", repoURL.path, "log", "--oneline"]
    )
    #expect(logOutput.exitCode == 0)
    #expect(logOutput.stdoutString.contains("Initialize invariants (v1)"))
  }

  @Test("Initializes with custom default branch")
  func initializeWithCustomBranch() async throws {
    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory.appendingPathComponent("init_custom_branch_\(UUID().uuidString)")
    let repoURL = tmpDir.appendingPathComponent("test-project")
    let keyURL = tmpDir.appendingPathComponent("id_p256")

    try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    _ = try await SubprocessRunner.run(
      binary: .git, arguments: ["-C", repoURL.path, "init", "-b", "develop"])
    _ = try await SubprocessRunner.run(
      binary: .git, arguments: ["-C", repoURL.path, "config", "user.name", "Branch Tester"])
    _ = try await SubprocessRunner.run(
      binary: .git,
      arguments: ["-C", repoURL.path, "config", "user.email", "branch@invariants.local"])

    try SigningClient.generateThrowawayKey(at: keyURL)

    try await RepoLocator.withRepoRoot(repoURL) {
      let detected = (await GitClient.discoverRepoInfo()).branches.first?.name
      #expect(detected == "develop")

      var ast = ASTConfig()
      ast[SwiftLanguage.self] = ["main": SwiftLanguage.Config(indexStore: "build/Index.noindex/DataStore")]

      let options = InitOptions(
        engine: "^1.0.0",
        defaultBranch: "develop",
        languages: [.swift],
        ast: ast,
        keyURL: keyURL
      )

      try await InitManager.initialize(options: options)

      let loaded = try await RegistryManager.loadAndVerify()
      #expect(loaded.defaultBranch == "develop")
      #expect(loaded.languages == [.swift])
      #expect(loaded.ast[SwiftLanguage.self]["main"]?.indexStore == "build/Index.noindex/DataStore")
    }
  }

  @Test("Initializes with default engine version sets EngineVersion.defaultRange")
  func initializeWithDefaultEngineRange() async throws {
    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory.appendingPathComponent("init_default_engine_\(UUID().uuidString)")
    let repoURL = tmpDir.appendingPathComponent("test-project")
    let keyURL = tmpDir.appendingPathComponent("id_p256")

    try fm.createDirectory(at: repoURL, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    _ = try await SubprocessRunner.run(
      binary: .git, arguments: ["-C", repoURL.path, "init", "-b", "main"])
    _ = try await SubprocessRunner.run(
      binary: .git, arguments: ["-C", repoURL.path, "config", "user.name", "Default Engine Tester"])
    _ = try await SubprocessRunner.run(
      binary: .git,
      arguments: ["-C", repoURL.path, "config", "user.email", "engine@invariants.local"])

    try SigningClient.generateThrowawayKey(at: keyURL)

    try await RepoLocator.withRepoRoot(repoURL) {
      let options = InitOptions(
        languages: [.swift],
        ast: ASTConfig(),
        keyURL: keyURL
      )

      try await InitManager.initialize(options: options)

      let loaded = try await RegistryManager.loadAndVerify()
      #expect(loaded.engine == EngineVersion.defaultRange)
    }
  }
}
