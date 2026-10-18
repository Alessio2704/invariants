public import Foundation

/// Represents a single parsed line in an OpenSSH `allowed_signers` file.
/// Specification: `principals [options] keytype base64-key [comment]`
public struct AllowedSignerEntry: Equatable, Sendable {
  public var principals: [String]
  public var namespaces: [String]
  public var validAfter: Date?
  public var validBefore: Date?
  public var certAuthority: Bool
  public var keyType: String
  public var keyData: String
  public var comment: String?

  public static let dateFormatter: DateFormatter = {
    let df = DateFormatter()
    df.dateFormat = "yyyyMMddHHmmss"
    df.timeZone = TimeZone(secondsFromGMT: 0)
    df.locale = Locale(identifier: "en_US_POSIX")
    return df
  }()

  public init(
    principals: [String] = ["*"],
    namespaces: [String] = ["invariants"],
    validAfter: Date? = nil,
    validBefore: Date? = nil,
    certAuthority: Bool = false,
    keyType: String,
    keyData: String,
    comment: String? = nil
  ) {
    self.principals = principals
    self.namespaces = namespaces
    self.validAfter = validAfter
    self.validBefore = validBefore
    self.certAuthority = certAuthority
    self.keyType = keyType
    self.keyData = keyData
    self.comment = comment
  }

  /// Parses an OpenSSH allowed_signers entry line. Returns nil for empty lines or comments.
  public static func parse(line: String) -> Self? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

    var tokens: [String] = []
    var current = ""
    var inQuotes = false

    for char in trimmed {
      if char == "\"" {
        inQuotes.toggle()
        current.append(char)
      } else if (char == " " || char == "\t") && !inQuotes {
        if !current.isEmpty {
          tokens.append(current)
          current = ""
        }
      } else {
        current.append(char)
      }
    }
    if !current.isEmpty {
      tokens.append(current)
    }

    guard tokens.count >= 3 else { return nil }

    let principalsToken = tokens[0]
    let principals = principalsToken.split(separator: ",").map(String.init)

    var optionsToken: String?
    let keyTypeIndex: Int

    let possibleKeyType = tokens[1]
    if possibleKeyType.hasPrefix("ssh-") || possibleKeyType.hasPrefix("ecdsa-") || possibleKeyType.hasPrefix("sk-") {
      keyTypeIndex = 1
    } else {
      optionsToken = tokens[1]
      keyTypeIndex = 2
    }

    guard tokens.count > keyTypeIndex + 1 else { return nil }
    let keyType = tokens[keyTypeIndex]
    let keyData = tokens[keyTypeIndex + 1]
    let comment = tokens.count > keyTypeIndex + 2 ? tokens[(keyTypeIndex + 2)...].joined(separator: " ") : nil

    var namespaces: [String] = ["invariants"]
    var validAfter: Date?
    var validBefore: Date?
    var certAuthority = false

    if let optionsToken {
      let optionItems = splitOptions(optionsToken)
      for opt in optionItems {
        if opt.hasPrefix("namespaces=") {
          let val = unquote(String(opt.dropFirst("namespaces=".count)))
          namespaces = val.split(separator: ",").map(String.init)
        } else if opt.hasPrefix("valid-after=") {
          let val = unquote(String(opt.dropFirst("valid-after=".count)))
          validAfter = dateFormatter.date(from: val)
        } else if opt.hasPrefix("valid-before=") {
          let val = unquote(String(opt.dropFirst("valid-before=".count)))
          validBefore = dateFormatter.date(from: val)
        } else if opt == "cert-authority" {
          certAuthority = true
        }
      }
    }

    return Self(
      principals: principals,
      namespaces: namespaces,
      validAfter: validAfter,
      validBefore: validBefore,
      certAuthority: certAuthority,
      keyType: keyType,
      keyData: keyData,
      comment: comment
    )
  }

  /// Serializes the entry back into the canonical OpenSSH allowed_signers line format.
  public func serialize() -> String {
    let principalsStr = principals.joined(separator: ",")
    var options: [String] = []

    if certAuthority {
      options.append("cert-authority")
    }
    if !namespaces.isEmpty {
      options.append("namespaces=\"\(namespaces.joined(separator: ","))\"")
    }
    if let validAfter {
      options.append("valid-after=\"\(Self.dateFormatter.string(from: validAfter))\"")
    }
    if let validBefore {
      options.append("valid-before=\"\(Self.dateFormatter.string(from: validBefore))\"")
    }

    var parts: [String] = [principalsStr]
    if !options.isEmpty {
      parts.append(options.joined(separator: ","))
    }
    parts.append(keyType)
    parts.append(keyData)
    if let comment, !comment.isEmpty {
      parts.append(comment)
    }
    return parts.joined(separator: " ")
  }

  public func isExpired(at date: Date = Date()) -> Bool {
    guard let validBefore else { return false }
    return date > validBefore
  }

  public func isPremature(at date: Date = Date()) -> Bool {
    guard let validAfter else { return false }
    return date < validAfter
  }

  public func isActive(at date: Date = Date()) -> Bool {
    !isExpired(at: date) && !isPremature(at: date)
  }

  /// Matches against a raw public key string or key data.
  public func matches(keyString: String) -> Bool {
    let trimmed = keyString.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.contains(keyData) || trimmed.contains(keyType) && trimmed.contains(keyData)
  }

  // MARK: - Internal Parsing Helpers

  private static func splitOptions(_ str: String) -> [String] {
    var items: [String] = []
    var current = ""
    var inQuotes = false

    for char in str {
      if char == "\"" {
        inQuotes.toggle()
        current.append(char)
      } else if char == "," && !inQuotes {
        if !current.isEmpty {
          items.append(current)
          current = ""
        }
      } else {
        current.append(char)
      }
    }
    if !current.isEmpty {
      items.append(current)
    }
    return items
  }

  private static func unquote(_ str: String) -> String {
    var res = str.trimmingCharacters(in: .whitespacesAndNewlines)
    if res.hasPrefix("\"") && res.hasSuffix("\"") && res.count >= 2 {
      res = String(res.dropFirst().dropLast())
    }
    return res
  }
}

/// Strongly typed document representation of `invariants/allowed_signers`.
public struct AllowedSignersFile: Equatable, Sendable {
  public var entries: [AllowedSignerEntry]

  public init(entries: [AllowedSignerEntry] = []) {
    self.entries = entries
  }

  public init(content: String) {
    self.entries =
      content
      .split(separator: "\n")
      .compactMap { AllowedSignerEntry.parse(line: String($0)) }
  }

  public static func read(from url: URL) throws -> Self {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return Self()
    }
    let content = try String(contentsOf: url, encoding: .utf8)
    return Self(content: content)
  }

  public func serialize() -> String {
    entries.map { $0.serialize() }.joined(separator: "\n") + (entries.isEmpty ? "" : "\n")
  }

  public func write(to url: URL) throws {
    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let content = serialize()
    try content.write(to: url, atomically: true, encoding: .utf8)
  }

  /// Adds a public key to the allowed signers list.
  @discardableResult
  public mutating func addPublicKey(
    _ keyString: String,
    principal: String = "*",
    namespaces: [String] = ["invariants"]
  ) throws -> AllowedSignerEntry {
    let parts = keyString.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: " ", omittingEmptySubsequences: true)
      .map(String.init)
    guard parts.count >= 2 else {
      throw SystemError.fileIOError("Invalid SSH public key format: \(keyString)")
    }
    let keyType = parts[0]
    let keyData = parts[1]
    let comment = parts.count > 2 ? parts[2...].joined(separator: " ") : nil

    let entry = AllowedSignerEntry(
      principals: [principal],
      namespaces: namespaces,
      keyType: keyType,
      keyData: keyData,
      comment: comment
    )
    entries.append(entry)
    return entry
  }

  /// Revokes a key by setting `valid-before` to the specified timestamp (defaults to now).
  @discardableResult
  public mutating func revoke(keyDataOrSubstring: String, effectiveDate: Date = Date()) -> Int {
    var count = 0
    for i in 0..<entries.count {
      let matches =
        entries[i].keyData.contains(keyDataOrSubstring)
        || entries[i].matches(keyString: keyDataOrSubstring)
        || entries[i].principals.contains(keyDataOrSubstring)
        || entries[i].comment?.contains(keyDataOrSubstring) == true
      if matches {
        entries[i].validBefore = effectiveDate
        count += 1
      }
    }
    return count
  }

  /// Rotates an existing key with a sunset grace period, enrolling the new key starting now.
  public mutating func rotate(
    oldKeyDataOrSubstring: String,
    newPublicKeyString: String,
    sunsetDuration: TimeInterval = 86400,
    now: Date = Date()
  ) throws {
    var rotatedOld = false
    let sunsetDate = now.addingTimeInterval(sunsetDuration)

    for i in 0..<entries.count {
      if entries[i].keyData.contains(oldKeyDataOrSubstring) || entries[i].matches(keyString: oldKeyDataOrSubstring) {
        entries[i].validBefore = sunsetDate
        rotatedOld = true
      }
    }

    guard rotatedOld else {
      throw SystemError.fileIOError("Old signing key not found in allowed_signers.")
    }

    let parts = newPublicKeyString.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: " ", omittingEmptySubsequences: true)
      .map(String.init)
    guard parts.count >= 2 else {
      throw SystemError.fileIOError("Invalid new SSH public key: \(newPublicKeyString)")
    }
    let keyType = parts[0]
    let keyData = parts[1]
    let comment = parts.count > 2 ? parts[2...].joined(separator: " ") : nil

    let newEntry = AllowedSignerEntry(
      principals: ["*"],
      namespaces: ["invariants"],
      validAfter: now,
      validBefore: nil,
      keyType: keyType,
      keyData: keyData,
      comment: comment
    )
    entries.append(newEntry)
  }
}
