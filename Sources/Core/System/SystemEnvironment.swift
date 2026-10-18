public import Foundation

/// System configuration representing trusted anchors, binary paths, and environment roots.
public struct SystemEnvironment: Sendable {
  public static let standard = Self()

  public let rootURL: URL
  public let binURL: URL

  /// Default user signing key location at `~/.ssh/invariants_p256`.
  public static var defaultSigningKeyURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(SystemPaths.defaultKeySubpath)
  }

  public var versionsDirectoryURL: URL {
    rootURL.appendingPathComponent(SystemPaths.versionsDirectoryName)
  }

  public var currentVersionURL: URL {
    rootURL.appendingPathComponent(SystemPaths.currentLinkName)
  }

  /// Returns the installation URL for a kit by its directory name.
  public func kitURL(named name: String) -> URL {
    let inKits =
      currentVersionURL
      .appendingPathComponent(SystemPaths.kitsDirectorySubpath)
      .appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: inKits.path) {
      return inKits
    }
    return currentVersionURL.appendingPathComponent(name)
  }

  /// System environment root and binary locations, with optional overrides for testing and sandboxing.
  public init(rootURL: URL? = nil, binURL: URL? = nil) {
    if let rootURL {
      self.rootURL = rootURL
      self.binURL = binURL ?? rootURL.appendingPathComponent(SystemPaths.binaryRelativeSubpath)
    } else if let envPrefix = ProcessInfo.processInfo.environment[SystemPaths.prefixEnvVariable], !envPrefix.isEmpty {
      let root = URL(fileURLWithPath: envPrefix)
      self.rootURL = root
      self.binURL = binURL ?? root.appendingPathComponent(SystemPaths.binaryRelativeSubpath)
    } else {
      self.rootURL = SystemPaths.defaultPrefixURL
      self.binURL = binURL ?? SystemPaths.defaultBinaryURL
    }
  }
}
