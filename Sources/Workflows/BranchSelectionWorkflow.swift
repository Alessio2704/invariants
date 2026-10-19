import Core
import Foundation
import Managers
import Terminal

/// Interactive CLI workflow responsible for selecting the default trunk branch.
package enum BranchSelectionWorkflow {
  /// Resolves the default trunk branch for repository initialization.
  package static func selectDefaultBranch(explicitBranch: String? = nil) async -> String {
    if let explicitBranch, !explicitBranch.isEmpty {
      return explicitBranch
    }

    let repoInfo = await BranchSelectionManager.discoverRepoInfo()
    guard !repoInfo.branches.isEmpty else { return "main" }

    let options = repoInfo.branches.map { branch in
      TerminalPrompt.Option(value: branch.name, label: branch.name, annotation: branch.annotation)
    }

    return TerminalPrompt.promptSelection(
      title: "Discovered branches in this repository:",
      options: options,
      default: 0,
      customHandler: { $0 }
    ) ?? repoInfo.defaultBranch?.name ?? "main"
  }
}
