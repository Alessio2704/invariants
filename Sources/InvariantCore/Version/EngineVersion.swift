import Foundation

/// Central source of truth for the Invariants engine version.
public enum EngineVersion {
  /// The current semantic version of the Invariants engine binary.
  public static let current: String = "1.0.0"

  /// Returns the Semver representation of the current engine.
  public static var semver: Semver {
    Semver(string: current) ?? Semver(major: 1, minor: 0, patch: 0)
  }

  /// Formats the semver range requirement for registry.lock (e.g. "^1.0.0").
  public static var defaultRange: String {
    "^\(current)"
  }
}
