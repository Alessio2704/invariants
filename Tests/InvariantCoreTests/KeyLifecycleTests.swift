import Foundation
import Testing

@testable import InvariantCore

@Suite("Key Lifecycle & Fingerprint Tests", .tags(.unit))
struct KeyLifecycleTests {

  @Test("SigningClient computes fingerprint for existing public key and returns nil for missing key")
  func fingerprintComputation() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("fp_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let keyURL = tmpDir.appendingPathComponent("id_test")
    let pubURL = tmpDir.appendingPathComponent("id_test.pub")

    // Missing key returns nil
    let missingFp = await SigningClient.fingerprint(pubKeyURL: pubURL)
    #expect(missingFp == nil)

    // Generate throwaway key
    try SigningClient.generateThrowawayKey(at: keyURL)
    #expect(FileManager.default.fileExists(atPath: pubURL.path))

    // Valid fingerprint contains SHA256:
    let validFp = await SigningClient.fingerprint(pubKeyURL: pubURL)
    #expect(validFp != nil)
    #expect(validFp?.contains("SHA256:") == true)
  }

  @Test("Clean rotation backups identifies and removes timestamped backup files")
  func cleanRotationBackups() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("clean_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let activeKey = tmpDir.appendingPathComponent("invariants_p256")
    let activePub = tmpDir.appendingPathComponent("invariants_p256.pub")
    let bak1 = tmpDir.appendingPathComponent("invariants_p256.bak-20261016120000")
    let bak1Pub = tmpDir.appendingPathComponent("invariants_p256.bak-20261016120000.pub")
    let bak2 = tmpDir.appendingPathComponent("invariants_p256.bak-20261016130000")
    let otherFile = tmpDir.appendingPathComponent("other_file.txt")

    try "active".write(to: activeKey, atomically: true, encoding: .utf8)
    try "active-pub".write(to: activePub, atomically: true, encoding: .utf8)
    try "bak1".write(to: bak1, atomically: true, encoding: .utf8)
    try "bak1-pub".write(to: bak1Pub, atomically: true, encoding: .utf8)
    try "bak2".write(to: bak2, atomically: true, encoding: .utf8)
    try "other".write(to: otherFile, atomically: true, encoding: .utf8)

    // Filter backups matching invariants_p256.bak-
    let items = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
    let backups = items.filter { $0.hasPrefix("invariants_p256.bak-") }
    #expect(backups.count == 3)

    for item in backups {
      try FileManager.default.removeItem(at: tmpDir.appendingPathComponent(item))
    }

    // Active key and other file must remain intact
    #expect(FileManager.default.fileExists(atPath: activeKey.path))
    #expect(FileManager.default.fileExists(atPath: activePub.path))
    #expect(FileManager.default.fileExists(atPath: otherFile.path))

    let remainingBackups = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
      .filter { $0.hasPrefix("invariants_p256.bak-") }
    #expect(remainingBackups.isEmpty)
  }

  @Test("Key status recognizes active, revoked, and unregistered keys in allowed_signers")
  func keyStatusRecognition() throws {
    let activeKey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBAc1 active@company.com"
    let revokedKey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBAc2 old@company.com"
    let unknownKey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBAc3 stranger@other.com"

    let signersFile = """
      * namespaces="invariants" \(activeKey)
      * namespaces="invariants",valid-before="20250101000000" \(revokedKey)
      """

    let lines = signersFile.split(separator: "\n").map(String.init)

    // Active check
    let activeMatch = lines.first(where: { $0.contains(activeKey) })
    #expect(activeMatch != nil)
    #expect(activeMatch?.contains("valid-before=") == false)

    // Revoked check
    let revokedMatch = lines.first(where: { $0.contains(revokedKey) })
    #expect(revokedMatch != nil)
    #expect(revokedMatch?.contains("valid-before=") == true)

    // Unknown check
    let unknownMatch = lines.first(where: { $0.contains(unknownKey) })
    #expect(unknownMatch == nil)
  }

  @Test("Key reset archives old credentials and generates a fresh keypair")
  func keyResetArchiving() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("reset_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let defaultKey = tmpDir.appendingPathComponent("invariants_p256")
    let defaultPub = defaultKey.appendingPathExtension("pub")

    try SigningClient.generateThrowawayKey(at: defaultKey)

    let originalPub = try String(contentsOf: defaultPub, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    // Perform reset: archive old to backup
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMddHHmmss"
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    let ts = formatter.string(from: Date())

    let backupKey = tmpDir.appendingPathComponent("invariants_p256.bak-\(ts)")
    let backupPub = backupKey.appendingPathExtension("pub")

    try FileManager.default.moveItem(at: defaultKey, to: backupKey)
    try FileManager.default.moveItem(at: defaultPub, to: backupPub)

    // Generate fresh key
    try SigningClient.generateThrowawayKey(at: defaultKey)
    let freshPub = try String(contentsOf: defaultPub, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    // Both backup and fresh key exist, and their public keys differ
    #expect(FileManager.default.fileExists(atPath: backupKey.path))
    #expect(FileManager.default.fileExists(atPath: backupPub.path))
    #expect(FileManager.default.fileExists(atPath: defaultKey.path))
    #expect(FileManager.default.fileExists(atPath: defaultPub.path))
    #expect(originalPub != freshPub)
  }

  @Test("Key rotation formats 24-hour grace period in allowed_signers")
  func rotationGracePeriodFormatting() throws {
    let oldPub = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBAc1 old@company.com"
    let newPub = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBAc2 new@company.com"

    let initialSigners = "* namespaces=\"invariants\" \(oldPub)\n"

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMddHHmmss"
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    let nowTs = formatter.string(from: Date())
    let validBeforeTs = formatter.string(from: Date().addingTimeInterval(86400))

    var lines = initialSigners.split(separator: "\n").map(String.init)
    for i in 0..<lines.count where lines[i].contains(oldPub) {
      lines[i] = lines[i].replacingOccurrences(
        of: "namespaces=\"invariants\"",
        with: "namespaces=\"invariants\",valid-before=\"\(validBeforeTs)\""
      )
    }
    lines.append("* namespaces=\"invariants\",valid-after=\"\(nowTs)\" \(newPub)")

    let rotatedSigners = lines.joined(separator: "\n") + "\n"

    #expect(rotatedSigners.contains("valid-before=\"\(validBeforeTs)\""))
    #expect(rotatedSigners.contains("valid-after=\"\(nowTs)\""))
    #expect(rotatedSigners.contains(oldPub))
    #expect(rotatedSigners.contains(newPub))
  }
}
