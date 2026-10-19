import Foundation

extension GitClient {
  /// The mutually exclusive semantic role of a Git branch within a repository.
  public enum BranchRole: String, Sendable, Equatable, CaseIterable {
    /// The branch is both the checked-out active branch AND the remote trunk.
    case activeTrunk = "active trunk"

    /// The branch is the designated remote trunk, but not currently checked out.
    case remoteTrunk = "remote trunk"

    /// The branch is currently checked out, but is not the remote trunk.
    case active = "active"

    /// Recommended default trunk (e.g. "main") when no remote trunk is detected.
    case recommended = "recommended"

    /// Standard local branch.
    case standard = "standard"
  }
}
