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

    /// The default primary branch (first discovered branch, typically remote trunk or main).
    public var defaultBranch: BranchInfo? {
      branches.first
    }

    public init(
      currentBranch: BranchInfo?,
      remoteTrunk: BranchInfo?,
      branches: [BranchInfo]
    ) {
      self.currentBranch = currentBranch
      self.remoteTrunk = remoteTrunk
      self.branches = branches
    }

    public init(branches: [BranchInfo]) {
      self.currentBranch = branches.first(where: \.isActive)
      self.remoteTrunk = branches.first(where: \.isTrunk)
      self.branches = branches
    }
  }
}
