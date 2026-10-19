import Foundation

extension GitClient {
  /// The mutually exclusive semantic role of a Git branch within a repository.
  public enum BranchRole: Sendable, Equatable, CaseIterable {
    /// The branch is both the checked-out active branch AND the remote trunk.
    case activeTrunk

    /// The branch is the designated remote trunk, but not currently checked out.
    case remoteTrunk

    /// The branch is currently checked out, but is not the remote trunk.
    case active

    /// Recommended default trunk (e.g. "main") when no remote trunk is detected.
    case recommended

    /// Standard local branch.
    case standard

    /// Human-readable annotation describing this role for terminal display.
    public var annotation: String? {
      switch self {
      case .activeTrunk:
        return "remote trunk, current"
      case .remoteTrunk:
        return "remote trunk"
      case .active:
        return "current"
      case .recommended:
        return "recommended"
      case .standard:
        return nil
      }
    }
  }
}
