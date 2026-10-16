import Foundation
import Testing

@testable import InvariantCore

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
    let runner = SubprocessRunner()
    _ = try await runner.run(
      executableURL: SubprocessRunner.gitURL, arguments: ["-C", repoURL.path, "init", "-b", "main"])
    _ = try await runner.run(
      executableURL: SubprocessRunner.gitURL, arguments: ["-C", repoURL.path, "config", "user.name", "Init Tester"])
    _ = try await runner.run(
      executableURL: SubprocessRunner.gitURL,
      arguments: ["-C", repoURL.path, "config", "user.email", "tester@invariants.local"])

    // Generate throwaway key
    let signingClient = SigningClient()
    try signingClient.generateThrowawayKey(at: keyURL)

    // Run InitManager
    let gitClient = GitClient()
    let env = SystemEnvironment(customRoot: tmpDir.appendingPathComponent("fake_root"))
    let registryManager = RegistryManager(environment: env, signingClient: signingClient)
    let initManager = InitManager(registryManager: registryManager, gitClient: gitClient)

    let options = InitOptions(
      engineVersion: "1.0.0",
      swiftIndexStore: "build/Index.noindex/DataStore",
      tsconfigs: ["tsconfig.json"],
      keyURL: keyURL
    )

    try await initManager.initialize(repoRootURL: repoURL, options: options)

    // 1. Verify in-repo allowed_signers
    let signersURL = RegistryManager.allowedSignersURL(repoRoot: repoURL)
    #expect(fm.fileExists(atPath: signersURL.path))
    let signersContent = try String(contentsOf: signersURL, encoding: .utf8)
    let pubKey = try String(contentsOf: keyURL.appendingPathExtension("pub"), encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(signersContent.contains(pubKey))
    #expect(signersContent.contains("namespaces=\"invariants\""))

    // 2. Verify registry.lock and registry.lock.sig
    let lockURL = RegistryManager.registryURL(repoRoot: repoURL)
    let sigURL = RegistryManager.signatureURL(repoRoot: repoURL)
    #expect(fm.fileExists(atPath: lockURL.path))
    #expect(fm.fileExists(atPath: sigURL.path))

    // 3. Verify registry can be loaded and cryptographically verified
    let loaded = try await registryManager.loadAndVerify(repoRoot: repoURL, installedEngineVersion: "1.0.0")
    #expect(loaded.version == 1)
    #expect(loaded.defaultBranch == "main")
    #expect(loaded.project?.swift?.indexStore == "build/Index.noindex/DataStore")
    #expect(loaded.project?.ts?.tsconfig == ["tsconfig.json"])

    // 4. Verify .gitignore updated with invariants/.dev/
    let gitignoreURL = repoURL.appendingPathComponent(".gitignore")
    #expect(fm.fileExists(atPath: gitignoreURL.path))
    let gitignoreContent = try String(contentsOf: gitignoreURL, encoding: .utf8)
    #expect(gitignoreContent.contains("invariants/.dev/"))

    // 5. Verify NO git hooks hijacked
    let githooksDir = repoURL.appendingPathComponent(".githooks")
    #expect(!fm.fileExists(atPath: githooksDir.path))
    let configuredHooksPath = try await gitClient.getHooksPath(repoRoot: repoURL)
    #expect(configuredHooksPath == nil)

    // 6. Verify git commit exists with initial commit
    let logOutput = try await runner.run(
      executableURL: SubprocessRunner.gitURL,
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

    let runner = SubprocessRunner()
    _ = try await runner.run(
      executableURL: SubprocessRunner.gitURL, arguments: ["-C", repoURL.path, "init", "-b", "develop"])
    _ = try await runner.run(
      executableURL: SubprocessRunner.gitURL, arguments: ["-C", repoURL.path, "config", "user.name", "Branch Tester"])
    _ = try await runner.run(
      executableURL: SubprocessRunner.gitURL,
      arguments: ["-C", repoURL.path, "config", "user.email", "branch@invariants.local"])

    let signingClient = SigningClient()
    try signingClient.generateThrowawayKey(at: keyURL)

    let gitClient = GitClient()
    let detected = await gitClient.detectDefaultBranch(repoRoot: repoURL)
    #expect(detected == "develop")

    let env = SystemEnvironment(customRoot: tmpDir.appendingPathComponent("fake_root"))
    let registryManager = RegistryManager(environment: env, signingClient: signingClient)
    let initManager = InitManager(registryManager: registryManager, gitClient: gitClient)

    let options = InitOptions(
      engineVersion: "1.0.0",
      defaultBranch: "develop",
      keyURL: keyURL
    )

    try await initManager.initialize(repoRootURL: repoURL, options: options)

    let loaded = try await registryManager.loadAndVerify(repoRoot: repoURL, installedEngineVersion: "1.0.0")
    #expect(loaded.defaultBranch == "develop")
  }
}
