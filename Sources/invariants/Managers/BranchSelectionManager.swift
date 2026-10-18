import Foundation
import InvariantCore

/// CLI-aware orchestrator responsible for discovering and selecting git trunk branches.
enum BranchSelectionManager {
  /// Resolves the default trunk branch for repository initialization.
  static func selectDefaultBranch(explicitBranch: String? = nil, repoRootURL: URL) async -> String {
    if let explicitBranch, !explicitBranch.isEmpty {
      return explicitBranch
    }

    let branches = await GitClient.discoverBranches(repoRoot: repoRootURL)
    let currentBranch = await GitClient.currentBranch(repoRoot: repoRootURL)
    let remoteTrunk = await GitClient.detectRemoteTrunk(repoRoot: repoRootURL)

    guard !branches.isEmpty else { return "main" }

    let options = branches.map { b in
      var annotations: [String] = []
      if b == remoteTrunk {
        annotations.append("remote trunk")
      } else if b == "main" && remoteTrunk == nil {
        annotations.append("recommended")
      }
      if b == currentBranch {
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
    ) ?? branches[0]
  }
}
