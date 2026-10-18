import Core
import Foundation
import Terminal

/// Interactive CLI workflow to uninstall invariants engine and remove system symlinks.
package enum UninstallWorkflow {
  package static func execute(yes: Bool) async throws {
    let env = SystemEnvironment.standard

    print("Invariants Uninstaller")
    print("──────────────────────")
    print("Target root: \(env.rootURL.path)")
    print("Target bin:  \(env.binURL.path)")
    print("")

    if !yes && TerminalPrompt.isInteractive {
      let confirmed = TerminalPrompt.promptConfirmation(
        question: "Are you sure you want to completely uninstall invariants from your machine?",
        default: false
      )
      guard confirmed else {
        print("Uninstall aborted.")
        return
      }
    }

    let needsElevation =
      SubprocessRunner.requiresElevation(for: env.rootURL)
      || SubprocessRunner.requiresElevation(for: env.binURL)

    let token: ElevationToken?
    if needsElevation {
      token = try await Authorizer.authorizeElevation(
        reason: "Authorizing invariants uninstallation from \(env.rootURL.path)"
      )
    } else {
      token = nil
    }

    try await InstallationManager.uninstall(environment: env, token: token)
    print("✓ Invariants successfully uninstalled from \(env.rootURL.path).")
  }
}
