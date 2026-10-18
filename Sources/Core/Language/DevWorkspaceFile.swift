import Foundation

/// Represents an editor/IDE development file to scaffold in `invariants/.dev/`.
public struct DevWorkspaceFile: Sendable, Equatable {
  public var relativePath: String
  public var content: String

  public init(relativePath: String, content: String) {
    self.relativePath = relativePath
    self.content = content
  }
}
