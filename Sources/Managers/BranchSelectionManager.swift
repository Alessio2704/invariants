package import Core
import Foundation

/// Pure domain manager for discovering branch and repository information.
/// Headless: zero terminal prompting or CLI dependencies.
package enum BranchSelectionManager {
  /// Discovers repository branch information, active branch, and remote trunk in a single concurrent pass.
  package static func discoverRepoInfo() async -> GitClient.RepoInfo {
    await GitClient.discoverRepoInfo()
  }

}
