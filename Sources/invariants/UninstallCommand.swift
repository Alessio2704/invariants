import ArgumentParser
import Foundation
import InvariantCore

struct UninstallCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "uninstall",
    abstract: "Completely uninstall invariants engine and remove system symlinks."
  )

  @Flag(name: [.short, .long], help: "Bypass confirmation prompt.")
  var yes: Bool = false

  func run() async throws {
    let env = SystemEnvironment.standard
    let installer = InstallationManager()

    print("Invariants Uninstaller")
    print("──────────────────────")
    print("Target root: \(env.rootURL.path)")
    print("Target bin:  \(env.binURL.path)")
    print("")

    if !yes && CLIHelpers.isInteractive {
      let confirmed = CLIHelpers.promptConfirmation(
        question: "Are you sure you want to completely uninstall invariants from your machine?",
        default: false
      )
      guard confirmed else {
        print("Uninstall aborted.")
        return
      }
    }

    do {
      try await installer.uninstall(environment: env)
      print("✓ Invariants successfully uninstalled from \(env.rootURL.path).")
    } catch {
      fputs("Error: Uninstall failed: \(error)\n", stderr)
      throw ExitCode(1)
    }
  }
}
