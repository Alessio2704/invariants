import Foundation
import Testing

@testable import InvariantCore

@Suite("Registry Encoding & Verification", .tags(.unit))
struct RegistryTests {
  @Test("Canonical JSON serialization produces deterministic sorted keys")
  func canonicalJSONOrdering() {
    let reg = Registry(
      repo: "sample-repo",
      version: 8,
      engine: "^1.2.0",
      project: ProjectConfig(
        swift: SwiftProjectConfig(indexStore: "Index/DataStore"),
        ts: TSProjectConfig(tsconfig: ["tsconfig.json"])
      ),
      rules: [
        "tooling": "77de4e10",
        "no-raw-text": "a81b02d4",
      ]
    )

    let serialized = CanonicalJSON.serialize(reg)

    let expected = """
      {
        "engine": "^1.2.0",
        "project": {
          "swift": { "indexStore": "Index/DataStore" },
          "ts": { "tsconfig": ["tsconfig.json"] }
        },
        "repo": "sample-repo",
        "rules": {
          "no-raw-text": "a81b02d4",
          "tooling": "77de4e10"
        },
        "version": 8
      }

      """
    #expect(serialized == expected)
  }

  @Test("Canonical JSON round-trip serialization is identical")
  func canonicalJSONRoundTrip() throws {
    let original = Registry(
      repo: "test-repo",
      version: 3,
      engine: "^1.0.0",
      rules: ["toy": "abc12345"]
    )
    let jsonStr = CanonicalJSON.serialize(original)
    guard let data = jsonStr.data(using: .utf8) else {
      Issue.record("Failed to convert string to UTF-8 data")
      return
    }

    let parsed = try CanonicalJSON.parse(data: data)
    #expect(parsed == original)
    let reSerialized = CanonicalJSON.serialize(parsed)
    #expect(reSerialized == jsonStr)
  }

  @Test("Semver range matching behaves accurately")
  func semverRangeCheck() throws {
    let v1_0_0 = try #require(Semver(string: "1.0.0"))
    let v1_2_3 = try #require(Semver(string: "1.2.3"))
    let v2_0_0 = try #require(Semver(string: "2.0.0"))
    let v1_3_0 = try #require(Semver(string: "1.3.0"))

    let caret = SemverRange("^1.0.0")
    #expect(caret.satisfies(v1_0_0))
    #expect(caret.satisfies(v1_2_3))
    #expect(!caret.satisfies(v2_0_0))

    let tilde = SemverRange("~1.2.0")
    #expect(tilde.satisfies(v1_2_3))
    #expect(!tilde.satisfies(v1_3_0))
  }

  @Test("SSH keygen sign and verify with throwaway Ed25519 key")
  func signatureVerification() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let keyURL = tmpDir.appendingPathComponent("id_test_ed25519")
    let sshClient = SSHKeygenClient()
    try await sshClient.generateThrowawayKey(at: keyURL)

    // Read public key
    let pubKeyData = try Data(contentsOf: tmpDir.appendingPathComponent("id_test_ed25519.pub"))
    let pubKeyStr = (String(bytes: pubKeyData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

    let allowedSignersURL = tmpDir.appendingPathComponent("allowed_signers")
    let signersContent = "owner namespaces=\"invariants\" \(pubKeyStr)\n"
    try Data(signersContent.utf8).write(to: allowedSignersURL)

    let fakeEnv = SystemEnvironment(customRoot: tmpDir)
    let manager = RegistryManager(environment: fakeEnv, sshClient: sshClient)

    let repoDir = tmpDir.appendingPathComponent("repo")
    try FileManager.default.createDirectory(
      at: repoDir.appendingPathComponent("invariants"), withIntermediateDirectories: true)

    let reg = Registry(repo: "test-repo", version: 1, engine: "^1.0.0")
    try await manager.saveAndSign(registry: reg, repoRoot: repoDir, keyURL: keyURL)

    // Verify valid
    let loaded = try await manager.loadAndVerify(repoRoot: repoDir, installedEngineVersion: "1.0.0")
    #expect(loaded == reg)

    // Tamper registry.lock
    let lockURL = RegistryManager.registryURL(repoRoot: repoDir)
    var tamperedData = try Data(contentsOf: lockURL)
    tamperedData.append(Data("tampered".utf8))
    try tamperedData.write(to: lockURL)

    // Verification must throw signatureInvalid
    await #expect(throws: RegistryError.self) {
      _ = try await manager.loadAndVerify(repoRoot: repoDir, installedEngineVersion: "1.0.0")
    }
  }
}
