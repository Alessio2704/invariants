import ArgumentParser
import Foundation
import InvariantCore

struct SelfUpdateCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "self-update",
    abstract: "Download, verify, compile, and install an engine release tag."
  )

  @Argument(help: "Signed Git tag to update to (e.g. v1.0.1).")
  var tag: String

  @Option(name: .long, help: "Pre-built stage directory path for offline installation.")
  var stagePath: String?

  func run() async throws {
    let env = SystemEnvironment.standard
    let installer = InstallationManager()
    let runner = SubprocessRunner()
    let fm = FileManager.default

    let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag

    print("Invariants Self-Update: \(tag)")
    print("───────────────────────────────")

    if let stagePath {
      let stageURL = URL(fileURLWithPath: stagePath)
      guard fm.fileExists(atPath: stageURL.path) else {
        fputs("Error: Stage directory does not exist at \(stageURL.path)\n", stderr)
        throw ExitCode(1)
      }

      print("Installing from stage directory \(stageURL.path)...")
      do {
        try await installer.installVersion(version: version, stageDir: stageURL, environment: env)
        print("✓ Successfully installed invariants \(version) to \(env.rootURL.path)")
        return
      } catch {
        fputs("Error: Failed to install from stage directory: \(error)\n", stderr)
        throw ExitCode(1)
      }
    }

    // 1. Extract git archive into temporary sandbox
    let workDir = fm.temporaryDirectory.appendingPathComponent("self_update_\(UUID().uuidString)")
    try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: workDir) }

    print("Extracting \(tag) archive...")
    let archiveCmd = "\(SubprocessRunner.gitURL.path) archive '\(tag)' | /usr/bin/tar -x -C '\(workDir.path)'"
    let extractOutput = try await runner.run(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", archiveCmd]
    )
    guard extractOutput.exitCode == 0 else {
      fputs("Error: Failed to extract tag archive: \(extractOutput.stderrString)\n", stderr)
      throw ExitCode(1)
    }

    // 2. Build release binary
    print("Building release binary for \(tag)...")
    let buildOutput = try await runner.run(
      executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
      arguments: ["swift", "build", "-c", "release", "--package-path", workDir.path]
    )
    guard buildOutput.exitCode == 0 else {
      fputs("Error: Release build failed:\n\(buildOutput.stderrString)\n", stderr)
      throw ExitCode(1)
    }

    // 3. Run test suite
    print("Running verification test suite...")
    let testOutput = try await runner.run(
      executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
      arguments: ["swift", "test", "--package-path", workDir.path]
    )
    guard testOutput.exitCode == 0 else {
      fputs("Error: Tests failed on release candidate:\n\(testOutput.stderrString)\n", stderr)
      throw ExitCode(1)
    }

    // 4. Stage release layout
    let stageDir = fm.temporaryDirectory.appendingPathComponent("stage_\(UUID().uuidString)")
    try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: stageDir) }

    let builtBinary = workDir.appendingPathComponent(".build/release/invariants")
    try fm.copyItem(at: builtBinary, to: stageDir.appendingPathComponent("invariants"))

    let kitSwiftDest = stageDir.appendingPathComponent("kit-swift/Sources")
    try fm.createDirectory(at: kitSwiftDest, withIntermediateDirectories: true)
    try fm.copyItem(
      at: workDir.appendingPathComponent("Sources/InvariantKit"),
      to: kitSwiftDest.appendingPathComponent("InvariantKit"))
    try fm.copyItem(
      at: workDir.appendingPathComponent("templates/kit-swift/Package.swift"),
      to: stageDir.appendingPathComponent("kit-swift/Package.swift"))

    if fm.fileExists(atPath: workDir.appendingPathComponent("Package.resolved").path) {
      try fm.copyItem(
        at: workDir.appendingPathComponent("Package.resolved"),
        to: stageDir.appendingPathComponent("kit-swift/Package.resolved"))
    }

    // Build kit-ts if present
    let kitTsSrc = workDir.appendingPathComponent("kit-ts")
    if fm.fileExists(atPath: kitTsSrc.path) {
      _ = try? await runner.run(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "cd '\(kitTsSrc.path)' && npm ci --ignore-scripts && npm run build"]
      )
      let kitTsDest = stageDir.appendingPathComponent("kit-ts")
      try fm.createDirectory(at: kitTsDest, withIntermediateDirectories: true)
      if fm.fileExists(atPath: kitTsSrc.appendingPathComponent("dist").path) {
        try fm.copyItem(at: kitTsSrc.appendingPathComponent("dist"), to: kitTsDest.appendingPathComponent("dist"))
      }
      if fm.fileExists(atPath: kitTsSrc.appendingPathComponent("node_modules").path) {
        try fm.copyItem(
          at: kitTsSrc.appendingPathComponent("node_modules"), to: kitTsDest.appendingPathComponent("node_modules"))
      }
    }

    // 5. Installation via InstallationManager
    print("Installing version \(version) to \(env.rootURL.path)...")
    do {
      try await installer.installVersion(version: version, stageDir: stageDir, environment: env)
      print("✓ Successfully self-updated invariants to \(tag)!")
    } catch {
      fputs("Error: Installation failed: \(error)\n", stderr)
      throw ExitCode(1)
    }
  }
}
