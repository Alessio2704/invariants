public import Foundation

/// System configuration representing trusted anchors, binary paths, and environment roots.
public struct SystemEnvironment: Sendable {
  public static let standard = Self()

  public let rootURL: URL
  public let binURL: URL

  /// Default user signing key location at `~/.ssh/invariants_p256`.
  public static var defaultSigningKeyURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".ssh/invariants_p256")
  }

  public var versionsDirectoryURL: URL {
    rootURL.appendingPathComponent("versions")
  }

  public var currentVersionURL: URL {
    rootURL.appendingPathComponent("current")
  }

  public var kitSwiftURL: URL {
    currentVersionURL.appendingPathComponent("kit-swift")
  }

  /// System environment root and binary locations, with optional overrides for testing and sandboxing.
  public init(rootURL: URL? = nil, binURL: URL? = nil) {
    if let rootURL {
      self.rootURL = rootURL
      self.binURL = binURL ?? rootURL.appendingPathComponent("bin/invariants")
    } else if let envPrefix = ProcessInfo.processInfo.environment["INVARIANTS_PREFIX"], !envPrefix.isEmpty {
      let root = URL(fileURLWithPath: envPrefix)
      self.rootURL = root
      self.binURL = binURL ?? root.appendingPathComponent("bin/invariants")
    } else {
      self.rootURL = URL(fileURLWithPath: "/usr/local/invariants")
      self.binURL = binURL ?? URL(fileURLWithPath: "/usr/local/bin/invariants")
    }
  }
}
