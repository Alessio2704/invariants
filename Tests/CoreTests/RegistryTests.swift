import Foundation
import Testing

@testable import Core

@Suite("Registry Encoding & Verification", .tags(.unit))
struct RegistryTests {
  @Test("Canonical JSON serialization produces deterministic sorted keys")
  func canonicalJSONOrdering() {
    var ast = ASTConfig()
    ast[SwiftLanguage.self] = ["main": SwiftLanguage.Config(indexStore: "Index/DataStore")]
    ast[TypeScriptLanguage.self] = ["main": TypeScriptLanguage.Config(tsconfig: "tsconfig.json")]

    let reg = Registry(
      version: 8,
      engine: "^1.2.0",
      languages: [.swift, .ts],
      ast: ast,
      rules: [
        "tooling": "77de4e10",
        "no-raw-text": "a81b02d4",
      ]
    )

    let serialized = CanonicalJSON.serialize(reg)

    let expected = """
      {
        "ast": {
          "swift": {
            "main": { "indexStore": "Index/DataStore" }
          },
          "ts": {
            "main": { "tsconfig": "tsconfig.json" }
          }
        },
        "default_branch": "main",
        "engine": "^1.2.0",
        "languages": [
          "swift",
          "ts"
        ],
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
    var ast = ASTConfig()
    ast[SwiftLanguage.self] = ["main": SwiftLanguage.Config(indexStore: "Index/DataStore")]
    let original = Registry(
      version: 3,
      engine: "^1.0.0",
      languages: [.swift],
      ast: ast,
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

  @Test("Round-trip serialization for single-language multi-unit Swift repo (ios + vapor)")
  func swiftMultiUnitRoundTrip() throws {
    var ast = ASTConfig()
    ast[SwiftLanguage.self] = [
      "ios": SwiftLanguage.Config(indexStore: "ios/build/Index.noindex/DataStore"),
      "vapor": SwiftLanguage.Config(indexStore: "vapor/.build/debug/index/store"),
    ]
    let reg = Registry(
      version: 2,
      engine: "^1.0.0",
      languages: [.swift],
      ast: ast,
      rules: ["api-rule": "11223344"]
    )
    let json = CanonicalJSON.serialize(reg)
    let parsed = try CanonicalJSON.parse(data: Data(json.utf8))
    #expect(parsed == reg)
    #expect(parsed.ast[SwiftLanguage.self]["ios"]?.indexStore == "ios/build/Index.noindex/DataStore")
    #expect(parsed.ast[SwiftLanguage.self]["vapor"]?.indexStore == "vapor/.build/debug/index/store")
  }

  @Test("Round-trip serialization for single-language multi-unit TypeScript repo (web + bff)")
  func tsMultiUnitRoundTrip() throws {
    var ast = ASTConfig()
    ast[TypeScriptLanguage.self] = [
      "web": TypeScriptLanguage.Config(tsconfig: "web/tsconfig.json"),
      "bff": TypeScriptLanguage.Config(tsconfig: "bff/tsconfig.json"),
    ]
    let reg = Registry(
      version: 2,
      engine: "^1.0.0",
      languages: [.ts],
      ast: ast,
      rules: ["no-db-in-web": "aabbccdd"]
    )
    let json = CanonicalJSON.serialize(reg)
    let parsed = try CanonicalJSON.parse(data: Data(json.utf8))
    #expect(parsed == reg)
    #expect(parsed.ast[TypeScriptLanguage.self]["web"]?.tsconfig == "web/tsconfig.json")
    #expect(parsed.ast[TypeScriptLanguage.self]["bff"]?.tsconfig == "bff/tsconfig.json")
  }

  @Test("Round-trip serialization for polyglot 2x2 monorepo (swift: ios + vapor, ts: web + bff)")
  func polyglot2x2RoundTrip() throws {
    var ast = ASTConfig()
    ast[SwiftLanguage.self] = [
      "ios": SwiftLanguage.Config(indexStore: "ios/build/Index.noindex/DataStore"),
      "vapor": SwiftLanguage.Config(indexStore: "vapor/.build/debug/index/store"),
    ]
    ast[TypeScriptLanguage.self] = [
      "bff": TypeScriptLanguage.Config(tsconfig: "bff/tsconfig.json"),
      "web": TypeScriptLanguage.Config(tsconfig: "web/tsconfig.json"),
    ]
    let reg = Registry(
      version: 5,
      engine: "^1.0.0",
      languages: [.swift, .ts],
      ast: ast,
      rules: ["sync-contract": "deadbeef"]
    )
    let json = CanonicalJSON.serialize(reg)
    let parsed = try CanonicalJSON.parse(data: Data(json.utf8))
    #expect(parsed == reg)
    #expect(parsed.languages == [.swift, .ts])
    #expect(parsed.ast[SwiftLanguage.self].count == 2)
    #expect(parsed.ast[TypeScriptLanguage.self].count == 2)
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

    #expect(Semver(string: "1.0.-") == nil)
    #expect(Semver(string: "1.0.+build") == nil)
    #expect(Semver(string: "1.0")?.patch == 0)
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

      var ast = ASTConfig()
      ast[SwiftLanguage.self] = ["main": SwiftLanguage.Config(indexStore: "Index/DataStore")]
      let reg = Registry(version: 1, engine: "^1.0.0", languages: [.swift], ast: ast)
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
