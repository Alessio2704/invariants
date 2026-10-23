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
    let trimmed = line.trimmed
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
          var val = unquote(String(opt.dropFirst("valid-after=".count)))
          if val.hasSuffix("Z") || val.hasSuffix("z") {
            val.removeLast()
          }
          validAfter = dateFormatter.date(from: val)
        } else if opt.hasPrefix("valid-before=") {
          var val = unquote(String(opt.dropFirst("valid-before=".count)))
          if val.hasSuffix("Z") || val.hasSuffix("z") {
            val.removeLast()
          }
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
      options.append("valid-after=\"\(Self.dateFormatter.string(from: validAfter))Z\"")
    }
    if let validBefore {
      options.append("valid-before=\"\(Self.dateFormatter.string(from: validBefore))Z\"")
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
    let trimmed = keyString.trimmed
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
        }
        current = ""
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
    var res = str.trimmed
    if res.hasPrefix("\"") && res.hasSuffix("\"") && res.count >= 2 {
      res = String(res.dropFirst().dropLast())
    }
    return res
  }
}
