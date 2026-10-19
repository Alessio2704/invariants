import Foundation

extension GitClient {
  /// Information describing an individual Git branch and its semantic role.
  public struct BranchInfo: Sendable, Equatable, Identifiable {
    public var id: String { name }

    /// The name of the branch.
    public let name: String

    /// The non-overlapping semantic role of this branch in the repository.
    public let role: BranchRole

    public init(name: String, role: BranchRole) {
      self.name = name
      self.role = role
    }

    /// Whether this branch is currently checked out (active or activeTrunk).
    public var isActive: Bool {
      role == .active || role == .activeTrunk
    }

    /// Whether this branch is designated as the remote trunk (remoteTrunk or activeTrunk).
    public var isTrunk: Bool {
      role == .remoteTrunk || role == .activeTrunk
    }

    /// Whether this branch is the recommended default trunk fallback.
    public var isRecommended: Bool {
      role == .recommended
    }

    /// Human-readable annotation describing this branch's role for terminal display.
    public var annotation: String? {
      role.annotation
    }
  }
}
