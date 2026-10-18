import Core
import Foundation

/// Pure domain manager for discovering branch information in a repository.
/// Headless: zero terminal prompting or CLI dependencies.
package enum BranchSelectionManager {
  package struct BranchInfo: Sendable {
    package let branches: [String]
    package let currentBranch: String?
    package let remoteTrunk: String?

    package init(branches: [String], currentBranch: String?, remoteTrunk: String?) {
      self.branches = branches
      self.currentBranch = currentBranch
      self.remoteTrunk = remoteTrunk
    }
  }

  /// Discovers local branches, current branch, and remote trunk for the repository.
  package static func discoverBranchInfo() async -> BranchInfo {
    let branches = await GitClient.discoverBranches()
    let current = await GitClient.currentBranch()
    let trunk = await GitClient.detectRemoteTrunk()
    return BranchInfo(branches: branches, currentBranch: current, remoteTrunk: trunk)
  }
}
