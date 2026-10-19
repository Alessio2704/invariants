import Foundation

/// Semantic version representation: major.minor.patch.
public struct Semver: Sendable, Equatable, Comparable, CustomStringConvertible {
  public let major: Int
  public let minor: Int
  public let patch: Int

  public init(major: Int, minor: Int, patch: Int) {
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  public init?(string: String) {
    let clean = string.trimmed
      .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    let parts = clean.split(separator: ".")
    guard parts.count >= 2,
      let maj = Int(parts[0]),
      let min = Int(parts[1])
    else {
      return nil
    }
    let pat: Int
    if parts.count >= 3 {
      // Strip any build metadata or prerelease after hyphen/plus
      let patchPart = parts[2].split(whereSeparator: { $0 == "-" || $0 == "+" })[0]
      guard let p = Int(patchPart) else { return nil }
      pat = p
    } else {
      pat = 0
    }
    self.init(major: maj, minor: min, patch: pat)
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.major != rhs.major {
      return lhs.major < rhs.major
    }
    if lhs.minor != rhs.minor {
      return lhs.minor < rhs.minor
    }
    return lhs.patch < rhs.patch
  }

  public var description: String {
    "\(major).\(minor).\(patch)"
  }
}

/// Semver range matcher supporting exact ("1.0.0"), caret ("^1.2.0"), and tilde ("~1.2.0").
public struct SemverRange: Sendable, Equatable {
  public let raw: String

  public init(_ raw: String) {
    self.raw = raw.trimmed
  }

  public func satisfies(_ version: Semver) -> Bool {
    if raw == "*" || raw == "x" || raw.isEmpty {
      return true
    }

    if raw.hasPrefix("^") {
      let baseString = String(raw.dropFirst())
      guard let base = Semver(string: baseString) else { return false }
      if version < base { return false }
      if base.major > 0 {
        return version.major == base.major
      } else if base.minor > 0 {
        return version.major == 0 && version.minor == base.minor
      } else {
        return version == base
      }
    }

    if raw.hasPrefix("~") {
      let baseString = String(raw.dropFirst())
      guard let base = Semver(string: baseString) else { return false }
      if version < base { return false }
      return version.major == base.major && version.minor == base.minor
    }

    if raw.hasPrefix(">=") {
      let baseString = String(raw.dropFirst(2))
      guard let base = Semver(string: baseString) else { return false }
      return version >= base
    }

    if let exact = Semver(string: raw) {
      return version == exact
    }

    return false
  }
}
