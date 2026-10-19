package import Core
import Foundation

/// Pure domain manager for discovering branch information in a repository.
/// Headless: zero terminal prompting or CLI dependencies.
package enum BranchSelectionManager {
  package typealias BranchInfo = GitClient.BranchInfo

  /// Discovers local branches, current branch, and remote trunk for the repository in a single concurrent pass.
  package static func discoverBranchInfo() async -> BranchInfo {
    await GitClient.discoverBranchInfo()
  }
}
