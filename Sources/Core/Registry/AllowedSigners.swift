public import Foundation

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
    let content = try url.readUTF8()
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
    // SEC-08b: Guard against embedded newlines to prevent signer injection
    guard !keyString.contains("\n") && !keyString.contains("\r") else {
      throw SystemError.fileIOError("Invalid SSH public key: key string must not contain newline characters.")
    }

    let parts = keyString.trimmed
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
    let query = keyDataOrSubstring.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return 0 }
    var count = 0
    for i in 0..<entries.count {
      // SEC-08a: Require exact match on keyData, keyString, principal, or comment
      // Loose substring match on base64 keyData was prone to wiping all keys on short prefixes
      let matches =
        entries[i].keyData == query
        || entries[i].matches(keyString: query)
        || entries[i].principals.contains(query)
        || entries[i].comment == query
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
    let oldQuery = oldKeyDataOrSubstring.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !oldQuery.isEmpty else {
      throw SystemError.fileIOError("Old signing key identifier must not be empty.")
    }

    var rotatedOld = false
    let sunsetDate = now.addingTimeInterval(sunsetDuration)

    for i in 0..<entries.count {
      let matches =
        entries[i].keyData == oldQuery
        || entries[i].matches(keyString: oldQuery)
        || entries[i].principals.contains(oldQuery)
        || entries[i].comment == oldQuery
      if matches {
        entries[i].validBefore = sunsetDate
        rotatedOld = true
      }
    }

    guard rotatedOld else {
      throw SystemError.fileIOError("Old signing key not found in allowed_signers.")
    }

    let parts = newPublicKeyString.trimmed
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
