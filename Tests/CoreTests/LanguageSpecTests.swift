import Foundation
import Testing

@testable import Core

@Suite("LanguageSpec & Project Configuration Tests", .tags(.unit))
struct LanguageSpecTests {
  @Test("SupportedLanguage enum cases and raw values")
  func supportedLanguageCases() {
    #expect(!SupportedLanguage.allCases.isEmpty)
    for language in SupportedLanguage.allCases {
      #expect(!language.rawValue.isEmpty)
      #expect(!language.spec.displayName.isEmpty)
      #expect(!language.spec.ruleFileName.isEmpty)
    }
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
    var original = ProjectConfig()
    original[SwiftLanguage.self] = SwiftLanguage.Config(indexStore: "build/DataStore")
    original[TypeScriptLanguage.self] = TypeScriptLanguage.Config(tsconfig: [
      "tsconfig.json", "tsconfig.node.json",
    ])

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(ProjectConfig.self, from: data)

    #expect(decoded == original)
    #expect(decoded[SwiftLanguage.self]?.indexStore == "build/DataStore")
    #expect(decoded[TypeScriptLanguage.self]?.tsconfig == ["tsconfig.json", "tsconfig.node.json"])
  }

  @Test(
    "All supported languages define non-empty sourceExtensions",
    arguments: SupportedLanguage.allCases
  )
  func sourceExtensionsValidation(language: SupportedLanguage) {
    #expect(!language.spec.sourceExtensions.isEmpty)
    for ext in language.spec.sourceExtensions {
      #expect(!ext.hasPrefix("."), "sourceExtensions should be bare extensions without leading dots")
    }
  }

  @Test("AnyLanguageSpec hasSources accurately detects language files in sandbox")
  func languageHasSourcesDetection() throws {
    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    #expect(!SwiftLanguage.hasSources(in: tmpDir))
    #expect(!TypeScriptLanguage.hasSources(in: tmpDir))

    // Add Swift file
    let swiftFile = tmpDir.appendingPathComponent("main.swift")
    try Data("print(1)".utf8).write(to: swiftFile)
    #expect(SwiftLanguage.hasSources(in: tmpDir))
    #expect(!TypeScriptLanguage.hasSources(in: tmpDir))

    // Add TS file
    let tsFile = tmpDir.appendingPathComponent("index.ts")
    try Data("console.log(1)".utf8).write(to: tsFile)
    #expect(SwiftLanguage.hasSources(in: tmpDir))
    #expect(TypeScriptLanguage.hasSources(in: tmpDir))
  }

  @Test(
    "describeConfig returns fallback for unconfigured projects across all languages",
    arguments: SupportedLanguage.allCases
  )
  func describeConfigOutputs(language: SupportedLanguage) {
    let project = ProjectConfig()
    #expect(language.spec.describeConfig(in: project) == "none")
  }

  @Test(
    "Declarative executionSpec validation for every supported language",
    arguments: SupportedLanguage.allCases
  )
  func executionSpecProperties(language: SupportedLanguage) {
    let spec = language.spec.executionSpec
    #expect(spec.reporting.successExitCode == 0)

    switch spec.model {
    case .compiled(let compiled):
      #expect(!compiled.buildArguments.isEmpty)
      #expect(!compiled.artifactRelativePath.isEmpty)
      #expect(!compiled.sourceExtensions.isEmpty)
    case .interpreted(let interpreted):
      #expect(!interpreted.runtimeCommand.isEmpty)
      #expect(!interpreted.kitDirectoryName.isEmpty)
      #expect(!interpreted.kitRunnerRelativePath.isEmpty)
    }
  }

  @Test("RuleRunner.resolveRuntimeURL finds common system commands")
  func resolveRuntimeURL() {
    let shURL = RuleRunner.resolveRuntimeURL(command: "sh")
    #expect(shURL != nil)
    #expect(FileManager.default.fileExists(atPath: shURL?.path ?? ""))

    let nonExistent = RuleRunner.resolveRuntimeURL(command: "non_existent_binary_xyz_123")
    #expect(nonExistent == nil)
  }

  @Test(
    "devWorkspaceFiles yields valid editor workspace files for each supported language",
    arguments: SupportedLanguage.allCases
  )
  func devWorkspaceFilesGeneration(language: SupportedLanguage) {
    let repoURL = URL(fileURLWithPath: "/tmp/fake-repo")
    let env = SystemEnvironment(rootURL: URL(fileURLWithPath: "/tmp/fake-install"))

    let files = language.spec.devWorkspaceFiles(repoRootURL: repoURL, environment: env)
    #expect(!files.isEmpty)
    for file in files {
      #expect(!file.relativePath.isEmpty)
      #expect(!file.content.isEmpty)
    }
  }

  @Test("SwiftLanguage discoverCandidates finds index stores and build output directories")
  func swiftDiscoverCandidates() throws {
    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let candidateDir = tmpDir.appendingPathComponent("build/Index.noindex/DataStore")
    try fm.createDirectory(at: candidateDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    let candidates = SwiftLanguage.discoverCandidates(repoRootURL: tmpDir)
    #expect(candidates.contains("build/Index.noindex/DataStore"))
  }

  @Test("TypeScriptLanguage discoverCandidates finds tsconfig.json files")
  func tsDiscoverCandidates() throws {
    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    let rootTsconfig = tmpDir.appendingPathComponent("tsconfig.json")
    try Data("{}".utf8).write(to: rootTsconfig)

    let pkgTsconfigDir = tmpDir.appendingPathComponent("packages/api")
    try fm.createDirectory(at: pkgTsconfigDir, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: pkgTsconfigDir.appendingPathComponent("tsconfig.json"))

    let candidates = TypeScriptLanguage.discoverCandidates(repoRootURL: tmpDir)
    #expect(candidates.contains("tsconfig.json"))
    #expect(candidates.contains("packages/api/tsconfig.json"))
  }
}
