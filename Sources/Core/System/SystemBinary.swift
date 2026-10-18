public import Foundation

/// Trusted canonical system binaries on the host system.
public enum SystemBinary: String, Sendable, CaseIterable {
  case git = "/usr/bin/git"
  case sshKeygen = "/usr/bin/ssh-keygen"
  case xcrun = "/usr/bin/xcrun"
  case sudo = "/usr/bin/sudo"
  case tar = "/usr/bin/tar"
  case sh = "/bin/sh"
  case ln = "/bin/ln"
  case rm = "/bin/rm"
  case mkdir = "/bin/mkdir"
  case cp = "/bin/cp"
  case chmod = "/bin/chmod"
  case chown = "/usr/sbin/chown"

  public var url: URL {
    URL(fileURLWithPath: rawValue)
  }

  public var path: String {
    rawValue
  }
}
