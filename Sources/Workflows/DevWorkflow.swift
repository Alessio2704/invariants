import Core
import Foundation
import Managers
import Terminal

/// Interactive CLI workflow to scaffold autocompletion development workspaces.
package enum DevWorkflow {
  /// Generates the autocompletion development workspace and notifies the user.
  package static func execute() throws {
    try DevWorkspaceManager.generateWorkspace(in: RepoLocator.current)
    Terminal.success("Created autocompletion workspace in invariants/.dev/")
    Terminal.info("Open this folder in Xcode or VSCode for rule authoring autocomplete.")
  }
}
