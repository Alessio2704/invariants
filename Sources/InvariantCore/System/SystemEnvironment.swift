public import Foundation

/// System configuration representing trusted anchors and paths.
public struct SystemEnvironment: Sendable {
  public static let standard = Self()

  public let rootURL: URL
  public let binURL: URL

  /// Returns the repository-scoped allowed_signers URL.
  public static func allowedSignersURL(in repoRoot: URL) -> URL {
    repoRoot.appendingPathComponent("invariants/allowed_signers")
  }

  /// Default user signing key location at `~/.ssh/invariants_ed25519`.
  public static var defaultSigningKeyURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".ssh/invariants_ed25519")
  }

  public var floorsDirectoryURL: URL {
    rootURL.appendingPathComponent("floors")
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

  public var kitTsURL: URL {
    currentVersionURL.appendingPathComponent("kit-ts")
  }

  /// Default production root at `/usr/local/invariants` (or `INVARIANTS_PREFIX` if set).
  public init() {
    if let envPrefix = ProcessInfo.processInfo.environment["INVARIANTS_PREFIX"], !envPrefix.isEmpty {
      let root = URL(fileURLWithPath: envPrefix)
      self.rootURL = root
      self.binURL = root.appendingPathComponent("bin/invariants")
    } else {
      self.rootURL = URL(fileURLWithPath: "/usr/local/invariants")
      self.binURL = URL(fileURLWithPath: "/usr/local/bin/invariants")
    }
  }

  /// Internal test seam allowing unit and scenario tests to inject a sandboxed root.
  internal init(customRoot: URL, customBin: URL? = nil) {
    self.rootURL = customRoot
    self.binURL = customBin ?? customRoot.appendingPathComponent("bin/invariants")
  }
}
