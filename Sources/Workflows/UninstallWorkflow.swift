import Core
import Foundation
import Terminal

/// Interactive CLI workflow to uninstall invariants engine and remove system symlinks.
package enum UninstallWorkflow {
  package static func execute(yes: Bool) async throws {
    let env = SystemEnvironment.standard

    Terminal.header("Invariants Uninstaller")
    Terminal.field("Target root:", value: env.rootURL.path)
    Terminal.field("Target bin:", value: env.binURL.path)
    Terminal.line()

    if !yes {
      let confirmed = try TerminalPrompt.promptConfirmation(
        question: "Are you sure you want to completely uninstall invariants from your machine?",
        default: false
      )
      guard confirmed else {
        Terminal.info("Uninstall aborted.")
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
    Terminal.success("Invariants successfully uninstalled from \(env.rootURL.path).")
  }
}
