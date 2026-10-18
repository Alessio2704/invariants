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

    let info = await BranchSelectionManager.discoverBranchInfo()
    guard !info.branches.isEmpty else { return "main" }

    let options = info.branches.map { b in
      var annotations: [String] = []
      if b == info.remoteTrunk {
        annotations.append("remote trunk")
      } else if b == "main" && info.remoteTrunk == nil {
        annotations.append("recommended")
      }
      if b == info.currentBranch {
        annotations.append("current")
      }
      let ann = annotations.isEmpty ? nil : annotations.joined(separator: ", ")
      return TerminalPrompt.Option(value: b, label: b, annotation: ann)
    }

    return TerminalPrompt.promptSelection(
      title: "Discovered branches in this repository:",
      options: options,
      default: 0,
      customHandler: { $0 }
    ) ?? info.branches[0]
  }
}
