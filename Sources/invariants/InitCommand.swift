import ArgumentParser
import Foundation
import InvariantCore

struct InitCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "init",
    abstract: "Initialize invariants in a project, install git hook shims, and sign registry v1."
  )

  @Option(name: .long, help: "Unique identifier for this repository.")
  var repo: String?

  @Option(name: .long, help: "Default branch name (default: auto-detected or main).")
  var branch: String?

  @Option(name: .long, help: "Relative path to Swift index store (e.g. build/Index.noindex/DataStore).")
  var swiftIndex: String?

  @Option(name: .long, parsing: .upToNextOption, help: "Relative path(s) to tsconfig.json.")
  var tsconfig: [String] = []

  @Option(name: .long, help: "Custom SSH key path for signing.")
  var key: String?

  @Option(name: .long, help: "Explicit repository root path (used in testing).")
  var repoPath: String?

  func run() async throws {
    let repoRootURL: URL
    if let repoPath {
      repoRootURL = URL(fileURLWithPath: repoPath)
    } else if let found = CLIHelpers.findRepoRoot() {
      repoRootURL = found
    } else {
      fputs("Error: Not inside a git repository.\n", stderr)
      throw ExitCode(1)
    }

    let repoId = repo ?? repoRootURL.lastPathComponent.lowercased()
    let fm = FileManager.default
    let env = SystemEnvironment.standard
    let registryManager = RegistryManager(environment: env)
    let gitClient = GitClient()
    let runner = SubprocessRunner()

    print("Initializing invariants in \(repoRootURL.lastPathComponent) (repo ID: '\(repoId)')...")

    // 1. Offer Touch ID for sudo
    await Self.offerTouchIDForSudo(runner: runner)

    // 2. Detect project inputs interactively or via flags
    let configuredSwiftIndex = selectSwiftIndex(repoRootURL: repoRootURL)
    let configuredTsconfigs = selectTsconfigs(repoRootURL: repoRootURL)

    var projectConfig = ProjectConfig()
    if let idx = configuredSwiftIndex {
      projectConfig.swift = SwiftProjectConfig(indexStore: idx)
      print("Configured Swift indexStore: \(idx)")
    }
    if !configuredTsconfigs.isEmpty {
      projectConfig.ts = TSProjectConfig(tsconfig: configuredTsconfigs)
      print("Configured TS tsconfig: \(configuredTsconfigs.joined(separator: ", "))")
    }

    // 3. Setup hook shims
    let githooksDir = repoRootURL.appendingPathComponent(".githooks")
    try fm.createDirectory(at: githooksDir, withIntermediateDirectories: true)

    let preCommitURL = githooksDir.appendingPathComponent("pre-commit")
    let preCommitLocalURL = githooksDir.appendingPathComponent("pre-commit.local")
    if fm.fileExists(atPath: preCommitURL.path) {
      let existing = (try? String(contentsOf: preCommitURL, encoding: .utf8)) ?? ""
      if !existing.contains("invariants check") {
        if fm.fileExists(atPath: preCommitLocalURL.path) {
          try fm.removeItem(at: preCommitLocalURL)
        }
        try fm.moveItem(at: preCommitURL, to: preCommitLocalURL)
        print("Moved existing pre-commit hook to .githooks/pre-commit.local")
      }
    }

    let preCommitShim = """
      #!/bin/sh
      set -e
      LOCAL="$(git rev-parse --show-toplevel)/.githooks/pre-commit.local"
      if [ -f "$LOCAL" ]; then
        "$LOCAL" "$@"
      fi
      exec /usr/local/bin/invariants check --stage pre-commit
      """
    try preCommitShim.data(using: .utf8)?.write(to: preCommitURL, options: .atomic)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: preCommitURL.path)

    let prePushURL = githooksDir.appendingPathComponent("pre-push")
    let prePushLocalURL = githooksDir.appendingPathComponent("pre-push.local")
    if fm.fileExists(atPath: prePushURL.path) {
      let existing = (try? String(contentsOf: prePushURL, encoding: .utf8)) ?? ""
      if !existing.contains("invariants check") {
        if fm.fileExists(atPath: prePushLocalURL.path) {
          try fm.removeItem(at: prePushLocalURL)
        }
        try fm.moveItem(at: prePushURL, to: prePushLocalURL)
        print("Moved existing pre-push hook to .githooks/pre-push.local")
      }
    }

    let prePushShim = """
      #!/bin/sh
      set -e
      REFS="$(cat)"
      LOCAL="$(git rev-parse --show-toplevel)/.githooks/pre-push.local"
      if [ -f "$LOCAL" ]; then
        printf '%s\\n' "$REFS" | "$LOCAL" "$@"
      fi
      printf '%s\\n' "$REFS" | exec /usr/local/bin/invariants check --stage pre-push "$@"
      """
    try prePushShim.data(using: .utf8)?.write(to: prePushURL, options: .atomic)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: prePushURL.path)

    // 4. Configure core.hooksPath
    try await gitClient.setHooksPath(repoRoot: repoRootURL, path: ".githooks")
    print("Configured git core.hooksPath=.githooks")

    // 5. Update .gitignore
    let gitignoreURL = repoRootURL.appendingPathComponent(".gitignore")
    var gitignoreContent = (try? String(contentsOf: gitignoreURL, encoding: .utf8)) ?? ""
    if !gitignoreContent.contains("invariants/.dev/") {
      if !gitignoreContent.isEmpty && !gitignoreContent.hasSuffix("\n") {
        gitignoreContent.append("\n")
      }
      gitignoreContent.append("\n# Invariants dev workspace\ninvariants/.dev/\n")
      try gitignoreContent.data(using: .utf8)?.write(to: gitignoreURL, options: .atomic)
    }

    // 6. Create Registry v1
    let registry = Registry(
      repo: repoId,
      version: 1,
      engine: "^\(CLIHelpers.engineVersion)",
      project: projectConfig.isEmpty ? nil : projectConfig,
      rules: [:]
    )

    // 7. Resolve signing key & write in-repo allowed_signers
    guard let keyURL = CLIHelpers.promptForSigningKey(customPath: key, repoRoot: repoRootURL) else {
      fputs("Error: No SSH signing key selected. Specify --key <path> or generate ~/.ssh/invariants_ed25519\n", stderr)
      throw ExitCode(1)
    }

    try Self.writeInitialAllowedSigners(keyURL: keyURL, repoRootURL: repoRootURL)

    print("Signing registry v1 with \(keyURL.lastPathComponent)...")
    try await registryManager.saveAndSign(
      registry: registry,
      repoRoot: repoRootURL,
      keyURL: keyURL
    )

    // 8. Commit setup
    var paths = [
      ".githooks/pre-commit",
      ".githooks/pre-push",
      "invariants/allowed_signers",
      "invariants/registry.lock",
      "invariants/registry.lock.sig",
      ".gitignore",
    ]
    if fm.fileExists(atPath: preCommitLocalURL.path) { paths.append(".githooks/pre-commit.local") }
    if fm.fileExists(atPath: prePushLocalURL.path) { paths.append(".githooks/pre-push.local") }

    try await gitClient.commit(
      repoRoot: repoRootURL,
      paths: paths,
      message: "Initialize invariants (v1)"
    )

    print("✓ Invariants initialized successfully in \(repoRootURL.lastPathComponent) (registry v1).")
  }

  // MARK: - Helper Methods

  private func selectSwiftIndex(repoRootURL: URL) -> String? {
    if let swiftIndex {
      return swiftIndex
    }
    let candidates = Self.discoverSwiftIndexCandidates(repoRootURL: repoRootURL)
    guard !candidates.isEmpty else { return nil }

    if CLIHelpers.isInteractive {
      print("\nDiscovered Swift Index candidates:")
      for (idx, cand) in candidates.enumerated() {
        print("  [\(idx + 1)] \(cand)")
      }
      let choice = CLIHelpers.prompt(
        question: "Select candidate [1-\(candidates.count)] or enter path (press Enter to skip)")
      if let num = Int(choice), num >= 1, num <= candidates.count {
        return candidates[num - 1]
      }
      if !choice.isEmpty {
        return choice
      }
      return nil
    }

    return candidates.first
  }

  private func selectTsconfigs(repoRootURL: URL) -> [String] {
    if !tsconfig.isEmpty {
      return tsconfig
    }
    let candidates = Self.discoverTsconfigCandidates(repoRootURL: repoRootURL)
    guard !candidates.isEmpty else { return [] }

    if CLIHelpers.isInteractive {
      let joined = candidates.joined(separator: ", ")
      let confirm = CLIHelpers.promptConfirmation(question: "Use discovered tsconfig paths (\(joined))?", default: true)
      if confirm {
        return candidates
      }
      let custom = CLIHelpers.prompt(question: "Enter tsconfig relative path (press Enter to skip)")
      return custom.isEmpty ? [] : [custom]
    }

    return candidates
  }

  static func discoverSwiftIndexCandidates(repoRootURL: URL) -> [String] {
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

  static func discoverTsconfigCandidates(repoRootURL: URL) -> [String] {
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

  static func writeInitialAllowedSigners(keyURL: URL, repoRootURL: URL) throws {
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

  static func offerTouchIDForSudo(runner: SubprocessRunner) async {
    let sudoLocal = URL(fileURLWithPath: "/etc/pam.d/sudo_local")
    let fm = FileManager.default
    if fm.fileExists(atPath: sudoLocal.path) {
      if let content = try? String(contentsOf: sudoLocal, encoding: .utf8), content.contains("pam_tid.so") {
        return
      }
    }

    if CLIHelpers.isInteractive {
      let enable = CLIHelpers.promptConfirmation(
        question: "Would you like to enable Touch ID for sudo (/etc/pam.d/sudo_local)?",
        default: true
      )
      if enable {
        let cmd =
          "printf 'auth       sufficient     pam_tid.so\\n' > /etc/pam.d/sudo_local && chmod 644 /etc/pam.d/sudo_local"
        _ = try? await runner.run(
          executableURL: SubprocessRunner.sudoURL,
          arguments: ["/bin/sh", "-c", cmd]
        )
        print("✓ Touch ID for sudo enabled in /etc/pam.d/sudo_local")
      }
    }
  }
}
