import Foundation

extension GitClient {
  /// High-level repository branch state, guaranteeing at most one active branch and at most one trunk.
  public struct RepoInfo: Sendable, Equatable {
    /// The active checked-out branch, if not in detached HEAD state.
    public let currentBranch: BranchInfo?

    /// The remote trunk branch, if an origin/HEAD is established.
    public let remoteTrunk: BranchInfo?

    /// All discovered branches in prioritized order (remote trunk, main, or master first).
    public let branches: [BranchInfo]

    public init(
      currentBranch: BranchInfo?,
      remoteTrunk: BranchInfo?,
      branches: [BranchInfo]
    ) {
      self.currentBranch = currentBranch
      self.remoteTrunk = remoteTrunk
      self.branches = branches
    }
  }
}
