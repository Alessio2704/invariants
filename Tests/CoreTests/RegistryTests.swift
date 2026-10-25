import Foundation
import Testing

@testable import Core

@Suite("Registry Encoding & Verification", .tags(.unit))
struct RegistryTests {
  @Test("Canonical JSON serialization produces deterministic sorted keys")
  func canonicalJSONOrdering() {
    var languages = LanguagesConfig()
    languages[SwiftLanguage.self] = SwiftLanguage.Config(indexStore: "Index/DataStore")
    languages[TypeScriptLanguage.self] = TypeScriptLanguage.Config(tsconfig: ["tsconfig.json"])

    let reg = Registry(
      version: 8,
      engine: "^1.2.0",
      languages: languages,
      rules: [
        "tooling": "77de4e10",
        "no-raw-text": "a81b02d4",
      ]
    )

    let serialized = CanonicalJSON.serialize(reg)

    let expected = """
      {
        "default_branch": "main",
        "engine": "^1.2.0",
        "languages": {
          "swift": { "indexStore": "Index/DataStore" },
          "ts": { "tsconfig": ["tsconfig.json"] }
        },
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
    var languages = LanguagesConfig()
    languages[SwiftLanguage.self] = SwiftLanguage.Config(indexStore: "Index/DataStore")
    let original = Registry(
      version: 3,
      engine: "^1.0.0",
      languages: languages,
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

  @Test("CanonicalJSON.parse rejects malformed JSON with invalidCanonicalJSON")
  func invalidCanonicalJSONSyntax() {
    let badData = Data("not json at all".utf8)
    #expect {
      try CanonicalJSON.parse(data: badData)
    } throws: { error in
      guard let regErr = error as? RegistryError, case .invalidCanonicalJSON = regErr else { return false }
      return !regErr.description.isEmpty
    }
  }

  @Test("CanonicalJSON.parse rejects valid JSON with missing schema fields with decodingFailed")
  func decodingFailedSchema() {
    let schemaMismatch = Data("{\"unrelated\": 123}".utf8)
    #expect {
      try CanonicalJSON.parse(data: schemaMismatch)
    } throws: { error in
      guard let regErr = error as? RegistryError, case .decodingFailed = regErr else { return false }
      return !regErr.description.isEmpty
    }
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

  @Test("SigningClient sign and verify with throwaway key")
  func signatureVerification() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let keyURL = tmpDir.appendingPathComponent("id_test_p256")
    try SigningClient.generateThrowawayKey(at: keyURL)

    // Read public key
    let pubKeyStr = try tmpDir.appendingPathComponent("id_test_p256.pub").readTrimmedUTF8()

    let repoDir = tmpDir.appendingPathComponent("repo")
    let invariantsDir = repoDir.appendingPathComponent("invariants")
    try FileManager.default.createDirectory(at: invariantsDir, withIntermediateDirectories: true)

    try await RepoLocator.withRepoRoot(repoDir) {
      let allowedSignersURL = RegistryManager.allowedSignersURL()
      let signersContent = "* namespaces=\"invariants\" \(pubKeyStr)\n"
      try Data(signersContent.utf8).write(to: allowedSignersURL)

      var languages = LanguagesConfig()
      languages[SwiftLanguage.self] = SwiftLanguage.Config(indexStore: "Index/DataStore")
      let reg = Registry(version: 1, engine: "^1.0.0", languages: languages)
      try await RegistryManager.saveAndSign(registry: reg, keyURL: keyURL)

      // Verify valid
      let loaded = try await RegistryManager.loadAndVerify()
      #expect(loaded.version == reg.version)
      #expect(loaded.signersHash != nil)

      // Tamper registry.lock
      let lockURL = RegistryManager.registryURL()
      var tamperedData = try Data(contentsOf: lockURL)
      tamperedData.append(Data("tampered".utf8))
      try tamperedData.write(to: lockURL)

      // Verification must throw signatureInvalid
      await #expect(throws: RegistryError.self) {
        _ = try await RegistryManager.loadAndVerify()
      }
    }
  }
}
