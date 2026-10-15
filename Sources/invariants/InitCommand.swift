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

  @Option(name: .long, help: "Default branch name (default: main).")
  var branch: String = "main"

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

    print("Initializing invariants in \(repoRootURL.lastPathComponent) (repo ID: '\(repoId)')...")

    // 1. Detect project inputs
    var detectedSwiftIndex = swiftIndex
    if detectedSwiftIndex == nil {
      // Scan for standard index store locations
      let candidates = [
        "build/Index.noindex/DataStore",
        ".build/debug/index/store",
        ".build/arm64-apple-macosx/debug/index/store",
        ".build/index/store",
      ]
      for candidate in candidates where fm.fileExists(atPath: repoRootURL.appendingPathComponent(candidate).path) {
        detectedSwiftIndex = candidate
        break
      }
    }

    var detectedTsconfigs = tsconfig
    if detectedTsconfigs.isEmpty {
      if fm.fileExists(atPath: repoRootURL.appendingPathComponent("tsconfig.json").path) {
        detectedTsconfigs.append("tsconfig.json")
      }
    }

    var projectConfig = ProjectConfig()
    if let idx = detectedSwiftIndex {
      projectConfig.swift = SwiftProjectConfig(indexStore: idx)
      print("Configured Swift indexStore: \(idx)")
    }
    if !detectedTsconfigs.isEmpty {
      projectConfig.ts = TSProjectConfig(tsconfig: detectedTsconfigs)
      print("Configured TS tsconfig: \(detectedTsconfigs.joined(separator: ", "))")
    }

    // 2. Setup hook shims
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

    // 3. Configure core.hooksPath
    try await gitClient.setHooksPath(repoRoot: repoRootURL, path: ".githooks")
    print("Configured git core.hooksPath=.githooks")

    // 4. Update .gitignore
    let gitignoreURL = repoRootURL.appendingPathComponent(".gitignore")
    var gitignoreContent = (try? String(contentsOf: gitignoreURL, encoding: .utf8)) ?? ""
    if !gitignoreContent.contains("invariants/.dev/") {
      if !gitignoreContent.isEmpty && !gitignoreContent.hasSuffix("\n") {
        gitignoreContent.append("\n")
      }
      gitignoreContent.append("\n# Invariants dev workspace\ninvariants/.dev/\n")
      try gitignoreContent.data(using: .utf8)?.write(to: gitignoreURL, options: .atomic)
    }

    // 5. Create Registry v1
    let registry = Registry(
      repo: repoId,
      version: 1,
      engine: "^1.0.0",
      project: projectConfig.isEmpty ? nil : projectConfig,
      rules: [:]
    )

    // 6. Resolve signing key & Sign
    guard let keyURL = CLIHelpers.resolveSigningKey(customPath: key) else {
      fputs("Error: No SSH signing key found. Specify --key <path> or configure ~/.ssh/id_ed25519\n", stderr)
      throw ExitCode(1)
    }

    print("Signing registry v1 with \(keyURL.lastPathComponent)...")
    try await registryManager.saveAndSign(
      registry: registry,
      repoRoot: repoRootURL,
      keyURL: keyURL
    )

    // 7. Commit setup
    var paths = [
      ".githooks/pre-commit",
      ".githooks/pre-push",
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
}
