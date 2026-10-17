import Foundation
import Testing

@testable import InvariantCore

@Suite("LanguageSpec & Project Configuration Tests", .tags(.unit))
struct LanguageSpecTests {
  @Test("SupportedLanguage enum cases and raw values")
  func supportedLanguageCases() {
    #expect(SupportedLanguage.allCases.count == 2)
    #expect(SupportedLanguage.swift.rawValue == "swift")
    #expect(SupportedLanguage.ts.rawValue == "ts")
  }

  @Test("SwiftLanguage spec metadata and strongly typed Config")
  func swiftLanguageSpec() async throws {
    #expect(SwiftLanguage.language == .swift)
    #expect(SwiftLanguage.displayName == "Swift")
    #expect(SwiftLanguage.sourceExtensions == ["swift"])
    #expect(SwiftLanguage.ruleFileName == "rule.swift")

    let config = SwiftLanguage.Config(indexStore: "build/Index.noindex/DataStore")
    #expect(config.indexStore == "build/Index.noindex/DataStore")

    // Test auto-discovery in temporary repo
    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let candidateDir = tmpDir.appendingPathComponent("build/Index.noindex/DataStore")
    try fm.createDirectory(at: candidateDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    let discovered = await SwiftLanguage.autoDiscover(repoRoot: tmpDir)
    #expect(discovered != nil)
    #expect(discovered?.indexStore == "build/Index.noindex/DataStore")
  }

  @Test("TypeScriptLanguage spec metadata and strongly typed Config")
  func typeScriptLanguageSpec() async throws {
    #expect(TypeScriptLanguage.language == .ts)
    #expect(TypeScriptLanguage.displayName == "TypeScript")
    #expect(TypeScriptLanguage.sourceExtensions.contains("ts"))
    #expect(TypeScriptLanguage.sourceExtensions.contains("tsx"))
    #expect(TypeScriptLanguage.ruleFileName == "rule.ts")

    let config = TypeScriptLanguage.Config(tsconfig: ["tsconfig.json", "packages/web/tsconfig.json"])
    #expect(config.tsconfig.count == 2)
    #expect(config.tsconfig[0] == "tsconfig.json")

    // Test auto-discovery in temporary repo
    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    let rootTsconfig = tmpDir.appendingPathComponent("tsconfig.json")
    try Data("{}".utf8).write(to: rootTsconfig)

    let pkgTsconfigDir = tmpDir.appendingPathComponent("packages/api")
    try fm.createDirectory(at: pkgTsconfigDir, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: pkgTsconfigDir.appendingPathComponent("tsconfig.json"))

    let discovered = await TypeScriptLanguage.autoDiscover(repoRoot: tmpDir)
    #expect(discovered != nil)
    let paths = discovered?.tsconfig ?? []
    #expect(paths.contains("tsconfig.json"))
    #expect(paths.contains("packages/api/tsconfig.json"))
  }

  @Test("ProjectConfig type-safe subscripting and configuration state")
  func projectConfigSubscripting() {
    var project = ProjectConfig()
    #expect(project.isEmpty)
    #expect(!project.isConfigured(.swift))
    #expect(!project.isConfigured(.ts))
    #expect(project[SwiftLanguage.self] == nil)
    #expect(project[TypeScriptLanguage.self] == nil)

    // Set Swift config
    project[SwiftLanguage.self] = SwiftLanguage.Config(indexStore: "DataStore")
    #expect(!project.isEmpty)
    #expect(project.isConfigured(.swift))
    #expect(!project.isConfigured(.ts))
    #expect(project[SwiftLanguage.self]?.indexStore == "DataStore")

    // Set TypeScript config
    project[TypeScriptLanguage.self] = TypeScriptLanguage.Config(tsconfig: ["tsconfig.json"])
    #expect(project.isConfigured(.swift))
    #expect(project.isConfigured(.ts))
    #expect(project[TypeScriptLanguage.self]?.tsconfig == ["tsconfig.json"])

    // Remove Swift config via subscript
    project[SwiftLanguage.self] = nil
    #expect(!project.isConfigured(.swift))
    #expect(project.isConfigured(.ts))
    #expect(project[SwiftLanguage.self] == nil)
  }

  @Test("ProjectConfig JSON serialization round-trip")
  func projectConfigCodable() throws {
    let original = ProjectConfig(
      swift: SwiftLanguage.Config(indexStore: "build/DataStore"),
      ts: TypeScriptLanguage.Config(tsconfig: ["tsconfig.json", "tsconfig.node.json"])
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(ProjectConfig.self, from: data)

    #expect(decoded == original)
    #expect(decoded[SwiftLanguage.self]?.indexStore == "build/DataStore")
    #expect(decoded[TypeScriptLanguage.self]?.tsconfig == ["tsconfig.json", "tsconfig.node.json"])
  }
}
