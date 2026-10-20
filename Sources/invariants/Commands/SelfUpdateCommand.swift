import ArgumentParser
import Core
import Foundation
import Terminal

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
    do {
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
          Terminal.error("Could not authorize elevation: \(error)")
          throw ExitCode(1)
        }
      } else {
        token = nil
      }

      if let stagePath {
        let stageURL = URL(fileURLWithPath: stagePath)
        guard fm.fileExists(atPath: stageURL.path) else {
          Terminal.error("Stage directory does not exist at \(stageURL.path)")
          throw ExitCode(1)
        }

        Terminal.info("Installing from stage directory \(stageURL.path)...")
        do {
          try await InstallationManager.installVersion(
            version: version, stageDir: stageURL, environment: env, token: token)
          Terminal.success("Successfully installed invariants \(version) to \(env.rootURL.path)")
          return
        } catch {
          Terminal.error("Failed to install from stage directory: \(error)")
          throw ExitCode(1)
        }
      }

      // 1. Extract git archive into temporary sandbox
      let workDir = fm.temporaryDirectory.appendingPathComponent("self_update_\(UUID().uuidString)")
      try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
      defer { try? fm.removeItem(at: workDir) }

      Terminal.info("Extracting \(tag) archive...")
      let archiveCmd =
        "\(SystemBinary.git.path) archive '\(tag)' | \(SystemBinary.tar.path) -x -C '\(workDir.path)'"
      let extractOutput = try await SubprocessRunner.runShell(archiveCmd)
      guard extractOutput.exitCode == 0 else {
        Terminal.error("Failed to extract tag archive: \(extractOutput.stderrString)")
        throw ExitCode(1)
      }

      // 2. Build release binary
      Terminal.info("Building release binary for \(tag)...")
      let buildOutput = try await SubprocessRunner.run(
        binary: .xcrun,
        arguments: ["swift", "build", "-c", "release", "--package-path", workDir.path]
      )
      guard buildOutput.exitCode == 0 else {
        Terminal.error("Release build failed:\n\(buildOutput.stderrString)")
        throw ExitCode(1)
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
        if let kitNames = try? fm.contentsOfDirectory(atPath: kitsDest.path) {
          for kitName in kitNames where !kitName.hasPrefix(".") {
            _ = try? fm.createSymbolicLink(
              at: stageDir.appendingPathComponent(kitName),
              withDestinationURL: URL(fileURLWithPath: "kits/\(kitName)")
            )
          }
        }
      }

      // 5. Installation via InstallationManager
      Terminal.info("Installing version \(version) to \(env.rootURL.path)...")
      do {
        try await InstallationManager.installVersion(
          version: version, stageDir: stageDir, environment: env, token: token)
        Terminal.success("Successfully self-updated invariants to \(tag)!")
      } catch {
        Terminal.error("Installation failed: \(error)")
        throw ExitCode(1)
      }
    } catch let exitCode as ExitCode {
      throw exitCode
    } catch {
      Terminal.error(error.localizedDescription)
      throw ExitCode(1)
    }
  }
}
