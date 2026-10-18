import Foundation
import Testing

@testable import Core

@Suite("Allowed Signers Domain Model & Parsing Tests", .tags(.unit))
struct AllowedSignersTests {

  @Test("Parse standard OpenSSH entry with namespaces option")
  func parseStandardEntry() {
    let line = "* namespaces=\"invariants\" ecdsa-sha2-nistp256 AAAAE2VjZHNh... alice@mac"
    let entry = AllowedSignerEntry.parse(line: line)

    #expect(entry != nil)
    #expect(entry?.principals == ["*"])
    #expect(entry?.namespaces == ["invariants"])
    #expect(entry?.keyType == "ecdsa-sha2-nistp256")
    #expect(entry?.keyData == "AAAAE2VjZHNh...")
    #expect(entry?.comment == "alice@mac")
    #expect(entry?.validBefore == nil)
    #expect(entry?.validAfter == nil)
    #expect(entry?.isActive() == true)
  }

  @Test("Parse entry with valid-before and valid-after options")
  func parseEntryWithOptions() throws {
    let line = [
      "alice@company.com",
      "namespaces=\"invariants\",valid-after=\"20260101000000\",valid-before=\"20261231235959\"",
      "ecdsa-sha2-nistp256",
      "AAAAE2VjZHNh...",
      "comment",
    ].joined(separator: " ")
    let entry = AllowedSignerEntry.parse(line: line)

    #expect(entry != nil)
    #expect(entry?.principals == ["alice@company.com"])
    #expect(entry?.namespaces == ["invariants"])
    #expect(entry?.keyType == "ecdsa-sha2-nistp256")
    #expect(entry?.keyData == "AAAAE2VjZHNh...")
    #expect(entry?.validAfter != nil)
    #expect(entry?.validBefore != nil)

    // Test expiration logic
    let pastDate = try #require(AllowedSignerEntry.dateFormatter.date(from: "20250101000000"))
    let activeDate = try #require(AllowedSignerEntry.dateFormatter.date(from: "20260601000000"))
    let futureDate = try #require(AllowedSignerEntry.dateFormatter.date(from: "20270101000000"))

    #expect(entry?.isPremature(at: pastDate) == true)
    #expect(entry?.isActive(at: pastDate) == false)

    #expect(entry?.isActive(at: activeDate) == true)
    #expect(entry?.isExpired(at: activeDate) == false)

    #expect(entry?.isExpired(at: futureDate) == true)
    #expect(entry?.isActive(at: futureDate) == false)
  }

  @Test("Round-trip serialization preserves exact format")
  func roundTripSerialization() {
    let original = "* namespaces=\"invariants\" ecdsa-sha2-nistp256 AAAAE2VjZHNh... test@lead"
    let entry = AllowedSignerEntry.parse(line: original)
    #expect(entry != nil)
    #expect(entry?.serialize() == original)
  }

  @Test("AllowedSignersFile add, revoke, and rotate operations")
  func fileOperations() throws {
    var file = AllowedSignersFile()
    #expect(file.entries.isEmpty)

    // 1. Add key
    let oldKey = "ecdsa-sha2-nistp256 AAAAE2VjZHNh1... old@mac"
    try file.addPublicKey(oldKey, principal: "*", namespaces: ["invariants"])
    #expect(file.entries.count == 1)
    #expect(file.entries[0].isActive() == true)

    // 2. Rotate key with sunset duration
    let newKey = "ecdsa-sha2-nistp256 AAAAE2VjZHNh2... new@mac"
    let now = Date()
    try file.rotate(
      oldKeyDataOrSubstring: "AAAAE2VjZHNh1...", newPublicKeyString: newKey, sunsetDuration: 86400, now: now)

    #expect(file.entries.count == 2)
    #expect(file.entries[0].validBefore != nil)
    #expect(file.entries[1].validAfter != nil)
    #expect(file.entries[1].keyData == "AAAAE2VjZHNh2...")

    // 3. Revoke
    let revoked = file.revoke(keyDataOrSubstring: "AAAAE2VjZHNh2...", effectiveDate: now)
    #expect(revoked > 0)
    #expect(file.entries[1].validBefore != nil)
  }

  @Test("File disk write and read round-trip")
  func fileReadWriteDisk() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("as_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let fileURL = tmpDir.appendingPathComponent("allowed_signers")
    var file = AllowedSignersFile()
    try file.addPublicKey("ecdsa-sha2-nistp256 AAAAE2VjZHNh... dev@plans")
    try file.write(to: fileURL)

    #expect(FileManager.default.fileExists(atPath: fileURL.path))

    let loaded = try AllowedSignersFile.read(from: fileURL)
    #expect(loaded.entries.count == 1)
    #expect(loaded.entries[0].keyType == "ecdsa-sha2-nistp256")
    #expect(loaded.entries[0].keyData == "AAAAE2VjZHNh...")
  }
}
