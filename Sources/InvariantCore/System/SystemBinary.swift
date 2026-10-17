public import Foundation

/// Trusted canonical system binaries on the host system.
public enum SystemBinary: String, Sendable, CaseIterable {
  case git = "/usr/bin/git"
  case sshKeygen = "/usr/bin/ssh-keygen"
  case xcrun = "/usr/bin/xcrun"
  case sudo = "/usr/bin/sudo"
  case tar = "/usr/bin/tar"
  case sh = "/bin/sh"

  public var url: URL {
    URL(fileURLWithPath: rawValue)
  }

  public var path: String {
    rawValue
  }
}
