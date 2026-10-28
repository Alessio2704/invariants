import Core
import Foundation
import Terminal

package enum SelfUpdateWorkflowError: LocalizedError, Sendable {
  case elevationFailed(String)
  case stageDirectoryNotFound(String)
  case archiveExtractionFailed(String)
  case buildFailed(String)
  case installationFailed(String)

  package var errorDescription: String? {
    switch self {
    case .elevationFailed(let msg):
      return "Could not authorize elevation: \(msg)"
    case .stageDirectoryNotFound(let path):
      return "Stage directory does not exist at \(path)"
    case .archiveExtractionFailed(let stderr):
      return "Failed to extract tag archive: \(stderr)"
    case .buildFailed(let stderr):
      return "Release build failed:\n\(stderr)"
    case .installationFailed(let msg):
      return "Installation failed: \(msg)"
    }
  }
}

/// Interactive CLI workflow to download, build, and self-update the invariants engine.
package enum SelfUpdateWorkflow {
  /// Executes the self-update process from an existing stage directory or by building a git release tag.
  package static func execute(tag: String, stagePath: String?) async throws {
    let env = SystemEnvironment.standard
    let fm = FileManager.default

    let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag

    Terminal.header("Invariants Self-Update: \(tag)")

    let needsElevation =
      SubprocessRunner.requiresElevation(for: env.rootURL)
      || SubprocessRunner.requiresElevation(for: env.binURL)

    let token: ElevationToken?
    if needsElevation {
      do {
        token = try await Authorizer.authorizeElevation(
          reason: "Authorizing invariants self-update to \(env.rootURL.path)"
        )
      } catch {
        throw SelfUpdateWorkflowError.elevationFailed(error.localizedDescription)
      }
    } else {
      token = nil
    }

    if let stagePath {
      let stageURL = URL(fileURLWithPath: stagePath)
      guard fm.fileExists(atPath: stageURL.path) else {
        throw SelfUpdateWorkflowError.stageDirectoryNotFound(stageURL.path)
      }

      Terminal.info("Installing from stage directory \(stageURL.path)...")
      do {
        try await InstallationManager.installVersion(
          version: version, stageDir: stageURL, environment: env, token: token)
        Terminal.success("Successfully installed invariants \(version) to \(env.rootURL.path)")
        return
      } catch {
        throw SelfUpdateWorkflowError.installationFailed(error.localizedDescription)
      }
    }

    // 1. Extract git archive into temporary sandbox or clone release tag
    let workDir = fm.temporaryDirectory.appendingPathComponent("self_update_\(UUID().uuidString)")
    try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: workDir) }

    // Validate tag format to prevent shell metacharacter injection or directory traversal
    let tagRegex = try? Regex("^[a-zA-Z0-9._/-]+$")
    guard let tagRegex, tag.wholeMatch(of: tagRegex) != nil, !tag.contains("..") else {
      throw SelfUpdateWorkflowError.archiveExtractionFailed("Invalid version tag format: '\(tag)'")
    }

    Terminal.info("Extracting \(tag) archive...")
    do {
      try await GitClient.archiveExtract(treeHash: tag, destinationURL: workDir)
    } catch {
      Terminal.info("Release tag '\(tag)' not found in local git working tree. Cloning from remote repository...")
      let repoURL =
        ProcessInfo.processInfo.environment["INVARIANTS_REPO"] ?? "https://github.com/Alessio2704/invariants.git"
      let cloneOutput = try await SubprocessRunner.run(
        binary: .git,
        arguments: ["clone", "--depth", "1", "--branch", tag, repoURL, workDir.path]
      )
      guard cloneOutput.exitCode == 0 else {
        throw SelfUpdateWorkflowError.archiveExtractionFailed(
          "Tag not found locally and clone failed:\n\(cloneOutput.stderrString)"
        )
      }
    }

    // 2. Build release binary
    Terminal.info("Building release binary for \(tag)...")
    let buildOutput = try await SubprocessRunner.run(
      binary: .xcrun,
      arguments: ["swift", "build", "-c", "release", "--package-path", workDir.path]
    )
    guard buildOutput.exitCode == 0 else {
      throw SelfUpdateWorkflowError.buildFailed(buildOutput.stderrString)
    }

    // 3. Stage release layout
    let stageDir = fm.temporaryDirectory.appendingPathComponent("stage_\(UUID().uuidString)")
    try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: stageDir) }

    let builtBinary = workDir.appendingPathComponent(".build/release/invariants")
    try fm.copyItem(at: builtBinary, to: stageDir.appendingPathComponent("invariants"))

    let kitsSrc = workDir.appendingPathComponent("kits")
    let kitsDest = stageDir.appendingPathComponent("kits")
    if fm.fileExists(atPath: kitsSrc.path) {
      try fm.copyItem(at: kitsSrc, to: kitsDest)

      let kitTsDir = kitsDest.appendingPathComponent("kit-ts")
      if fm.fileExists(atPath: kitTsDir.appendingPathComponent("package.json").path) {
        Terminal.info("Installing TypeScript kit runtime dependencies...")
        // DRIFT-07: Install runtime dependencies with npm ci (fallback npm install)
        let npmProc = Process()
        npmProc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        npmProc.arguments = ["npm", "ci", "--omit=dev", "--ignore-scripts"]
        npmProc.currentDirectoryURL = kitTsDir
        if (try? npmProc.run()) != nil {
          npmProc.waitUntilExit()
          if npmProc.terminationStatus != 0 {
            let fallback = Process()
            fallback.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            fallback.arguments = ["npm", "install", "--omit=dev", "--ignore-scripts"]
            fallback.currentDirectoryURL = kitTsDir
            try? fallback.run()
            fallback.waitUntilExit()
          }
        }
      }

      if let kitNames = try? fm.contentsOfDirectory(atPath: kitsDest.path) {
        for kitName in kitNames where !kitName.hasPrefix(".") {
          _ = try? fm.createSymbolicLink(
            at: stageDir.appendingPathComponent(kitName),
            withDestinationURL: URL(fileURLWithPath: "kits/\(kitName)")
          )
        }
      }
    }

    // 4. Installation via InstallationManager
    Terminal.info("Installing version \(version) to \(env.rootURL.path)...")
    do {
      try await InstallationManager.installVersion(
        version: version, stageDir: stageDir, environment: env, token: token)
      Terminal.success("Successfully self-updated invariants to \(tag)!")
    } catch {
      throw SelfUpdateWorkflowError.installationFailed(error.localizedDescription)
    }
  }
}
