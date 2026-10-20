import Core
import Foundation
import Managers
import Terminal

/// Errors that occur during branch selection.
package enum BranchSelectionError: LocalizedError, Sendable {
  case noBranchesFound

  package var errorDescription: String? {
    switch self {
    case .noBranchesFound:
      return "No git branches found in this repository."
    }
  }
}

/// Interactive CLI workflow responsible for selecting the default trunk branch.
package enum BranchSelectionWorkflow {
  /// Resolves the default trunk branch for repository initialization.
  package static func selectDefaultBranch(
    explicitBranch: String? = nil
  ) async throws(BranchSelectionError) -> String {
    if let explicitBranch, !explicitBranch.isEmpty {
      return explicitBranch
    }

    let repoInfo = await BranchSelectionManager.discoverRepoInfo()
    guard !repoInfo.branches.isEmpty else {
      throw BranchSelectionError.noBranchesFound
    }

    let options = repoInfo.branches.map { branch in
      TerminalPrompt.Option(value: branch.name, label: branch.name, annotation: branch.annotation)
    }

    guard Terminal.isInteractive else {
      if let defaultBranch = repoInfo.defaultBranch?.name {
        return defaultBranch
      }
      throw BranchSelectionError.noBranchesFound
    }

    do {
      guard
        let selected = try TerminalPrompt.promptSelection(
          title: "Discovered branches in this repository:",
          options: options,
          default: 0,
          customHandler: { $0 }
        )
      else {
        throw BranchSelectionError.noBranchesFound
      }
      return selected
    } catch {
      throw BranchSelectionError.noBranchesFound
    }
  }
}
