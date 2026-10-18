public import Foundation

/// Centralized canonical system paths, directory names, and environment variables for the invariants engine.
public enum SystemPaths: Sendable {
  /// Canonical install root path (`/usr/local/invariants`).
  public static let defaultPrefixPath: String = "/usr/local/invariants"

  /// Canonical install root URL.
  public static var defaultPrefixURL: URL {
    URL(fileURLWithPath: defaultPrefixPath)
  }

  /// Canonical global symlink path (`/usr/local/bin/invariants`).
  public static let defaultBinaryPath: String = "/usr/local/bin/invariants"

  /// Canonical global symlink URL.
  public static var defaultBinaryURL: URL {
    URL(fileURLWithPath: defaultBinaryPath)
  }

  /// Environment variable name for custom installation prefix override (`INVARIANTS_PREFIX`).
  public static let prefixEnvVariable: String = "INVARIANTS_PREFIX"

  /// Relative subpath from an installation root to its executable binary (`bin/invariants`).
  public static let binaryRelativeSubpath: String = "bin/invariants"

  /// Directory name for stored versions (`versions`).
  public static let versionsDirectoryName: String = "versions"

  /// Symlink name for active version (`current`).
  public static let currentLinkName: String = "current"

  /// Default SSH directory name (`.ssh`).
  public static let defaultKeyDirectoryName: String = ".ssh"

  /// Default signing key filename (`invariants_p256`).
  public static let defaultKeyFileName: String = "invariants_p256"

  /// Relative path under home directory for default key (`.ssh/invariants_p256`).
  public static let defaultKeySubpath: String = ".ssh/invariants_p256"

  /// Prefix for archived key backups (`invariants_p256.bak-`).
  public static let keyBackupPrefix: String = "invariants_p256.bak-"

  /// Relative subpath for developer workspace scaffolding (`invariants/.dev`).
  public static let devWorkspaceSubpath: String = "invariants/.dev"

  /// Relative subpath for rule language SDK kits (`kits`).
  public static let kitsDirectorySubpath: String = "kits"

  /// Universal directories and subpaths ignored across all file discovery and static analysis scans.
  public static let universalIgnoredPaths: [String] = [
    ".git",
    devWorkspaceSubpath,
    kitsDirectorySubpath,
  ]
}

extension SystemEnvironment {
  /// Typealias to `SystemPaths` for nested discovery under `SystemEnvironment.Paths`.
  public typealias Paths = SystemPaths
}
