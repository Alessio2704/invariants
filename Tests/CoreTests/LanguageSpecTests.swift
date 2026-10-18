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

  @Test("LanguagesConfig type-safe subscripting and configuration state")
  func languagesConfigSubscripting() {
    var languages = LanguagesConfig()
    #expect(languages.isEmpty)
    #expect(!languages.isConfigured(.swift))
    #expect(!languages.isConfigured(.ts))
    #expect(languages[SwiftLanguage.self] == nil)
    #expect(languages[TypeScriptLanguage.self] == nil)

    // Set Swift config
    languages[SwiftLanguage.self] = SwiftLanguage.Config(indexStore: "DataStore")
    #expect(!languages.isEmpty)
    #expect(languages.isConfigured(.swift))
    #expect(!languages.isConfigured(.ts))
    #expect(languages[SwiftLanguage.self]?.indexStore == "DataStore")

    // Set TypeScript config
    languages[TypeScriptLanguage.self] = TypeScriptLanguage.Config(tsconfig: ["tsconfig.json"])
    #expect(languages.isConfigured(.swift))
    #expect(languages.isConfigured(.ts))
    #expect(languages[TypeScriptLanguage.self]?.tsconfig == ["tsconfig.json"])

    // Remove Swift config via subscript
    languages[SwiftLanguage.self] = nil
    #expect(!languages.isConfigured(.swift))
    #expect(languages.isConfigured(.ts))
    #expect(languages[SwiftLanguage.self] == nil)

    // Polymorphic subscripting by SupportedLanguage
    languages[.swift] = SwiftLanguage.Config(indexStore: "DataStore")
    #expect(languages.isConfigured(.swift))
    let swiftCfg = languages[.swift] as? SwiftLanguage.Config
    #expect(swiftCfg?.indexStore == "DataStore")

    languages[.swift] = nil
    #expect(!languages.isConfigured(.swift))
    #expect(languages[.swift] == nil)
  }

  @Test("LanguagesConfig JSON serialization round-trip")
  func languagesConfigCodable() throws {
    var original = LanguagesConfig()
    original[SwiftLanguage.self] = SwiftLanguage.Config(indexStore: "build/DataStore")
    original[TypeScriptLanguage.self] = TypeScriptLanguage.Config(tsconfig: [
      "tsconfig.json", "tsconfig.node.json",
    ])

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(LanguagesConfig.self, from: data)

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
    let languages = LanguagesConfig()
    #expect(language.spec.describeConfig(in: languages) == "none")
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

  @Test(
    "All supported languages provide valid configPromptDescriptor and makeConfig factory",
    arguments: SupportedLanguage.allCases
  )
  func languageConfigFactoryAndDescriptor(language: SupportedLanguage) {
    let spec = language.spec
    let descriptor = spec.configPromptDescriptor
    #expect(!descriptor.noCandidatesMessage.isEmpty)
    #expect(!descriptor.manualPromptQuestion.isEmpty)

    switch descriptor.selectionStyle {
    case .single(let title):
      #expect(!title.isEmpty)
    case .multiple(let question):
      #expect(!question.isEmpty)
    }

    #expect(spec.makeConfig(from: []) == nil)
    #expect(spec.makeConfig(from: [""]) == nil)

    let sample = spec.makeConfig(from: ["sample/path"])
    #expect(sample != nil)
  }

  @Test("Polymorphic autoDiscover on AnyLanguageSpec")
  func polymorphicAutoDiscover() async throws {
    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(
      at: tmpDir.appendingPathComponent("build/Index.noindex/DataStore"),
      withIntermediateDirectories: true
    )
    try Data("{}".utf8).write(to: tmpDir.appendingPathComponent("tsconfig.json"))
    defer { try? fm.removeItem(at: tmpDir) }

    let swiftConfig = await SupportedLanguage.swift.spec.autoDiscover(repoRoot: tmpDir)
    #expect(swiftConfig != nil)
    #expect((swiftConfig as? SwiftLanguage.Config)?.indexStore == "build/Index.noindex/DataStore")

    let tsConfig = await SupportedLanguage.ts.spec.autoDiscover(repoRoot: tmpDir)
    #expect(tsConfig != nil)
    #expect((tsConfig as? TypeScriptLanguage.Config)?.tsconfig.contains("tsconfig.json") == true)
  }

  @Test("Language specifications declare default ignored paths and extensions under OCP")
  func defaultIgnoredPathsAndExtensions() {
    #expect(SwiftLanguage.defaultIgnoredPaths.contains(".build"))
    #expect(SwiftLanguage.defaultIgnoredPaths.contains("build"))
    #expect(SwiftLanguage.defaultIgnoredExtensions.isEmpty)

    #expect(TypeScriptLanguage.defaultIgnoredPaths.contains("node_modules"))
    #expect(TypeScriptLanguage.defaultIgnoredPaths.contains("dist"))
    #expect(TypeScriptLanguage.defaultIgnoredExtensions.contains("d.ts"))
    #expect(TypeScriptLanguage.defaultIgnoredExtensions.contains("map"))

    let allPaths = SupportedLanguage.allDefaultIgnoredPaths
    #expect(allPaths.contains(".git"))
    #expect(allPaths.contains("invariants/.dev"))
    #expect(allPaths.contains("kits"))
    #expect(allPaths.contains(".build"))
    #expect(allPaths.contains("build"))
    #expect(allPaths.contains("node_modules"))
    #expect(allPaths.contains("dist"))

    let allExts = SupportedLanguage.allDefaultIgnoredExtensions
    #expect(allExts.contains("d.ts"))
    #expect(allExts.contains("map"))
  }

  @Test("AnyLanguageSpec shouldSkip correctly filters ignored paths and extensions")
  func shouldSkipFiltering() {
    // Universal ignored paths
    #expect(SwiftLanguage.shouldSkip(relativePath: ".git/HEAD"))
    #expect(SwiftLanguage.shouldSkip(relativePath: "invariants/.dev/Package.swift"))
    #expect(SwiftLanguage.shouldSkip(relativePath: "kits/kit-swift/Package.swift"))
    #expect(TypeScriptLanguage.shouldSkip(relativePath: ".git/config"))
    #expect(TypeScriptLanguage.shouldSkip(relativePath: "invariants/.dev/rule.ts"))
    #expect(TypeScriptLanguage.shouldSkip(relativePath: "kits/kit-ts/tsconfig.json"))

    // Swift specific
    #expect(SwiftLanguage.shouldSkip(relativePath: ".build/debug/foo.o"))
    #expect(SwiftLanguage.shouldSkip(relativePath: "build/foo.swift"))
    #expect(!SwiftLanguage.shouldSkip(relativePath: "Sources/App.swift"))

    // TypeScript specific
    #expect(TypeScriptLanguage.shouldSkip(relativePath: "node_modules/pkg/index.js"))
    #expect(TypeScriptLanguage.shouldSkip(relativePath: "dist/bundle.js"))
    #expect(TypeScriptLanguage.shouldSkip(relativePath: "src/types.d.ts"))
    #expect(TypeScriptLanguage.shouldSkip(relativePath: "src/bundle.js.map"))
    #expect(!TypeScriptLanguage.shouldSkip(relativePath: "src/index.ts"))

    // Aggregated skipping
    #expect(SupportedLanguage.shouldSkipAny(relativePath: "node_modules/pkg/index.js"))
    #expect(SupportedLanguage.shouldSkipAny(relativePath: ".build/out"))
    #expect(SupportedLanguage.shouldSkipAny(relativePath: "invariants/.dev/test"))
    #expect(!SupportedLanguage.shouldSkipAny(relativePath: "Sources/Core/Engine.swift"))
  }

  @Test("hasSources accurately ignores build directories, node_modules, and ignored extensions")
  func hasSourcesIgnoresBuildAndDependencies() throws {
    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    // Initially empty
    #expect(!SwiftLanguage.hasSources(in: tmpDir))
    #expect(!TypeScriptLanguage.hasSources(in: tmpDir))

    // Swift file inside node_modules or .build should NOT count as sources
    let nodeModulesSwift = tmpDir.appendingPathComponent("node_modules/fake-pod/File.swift")
    try fm.createDirectory(at: nodeModulesSwift.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("// swift".utf8).write(to: nodeModulesSwift)

    let buildSwift = tmpDir.appendingPathComponent(".build/Generated.swift")
    try fm.createDirectory(at: buildSwift.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("// swift".utf8).write(to: buildSwift)

    let devSwift = tmpDir.appendingPathComponent("invariants/.dev/Dev.swift")
    try fm.createDirectory(at: devSwift.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("// swift".utf8).write(to: devSwift)

    #expect(!SwiftLanguage.hasSources(in: tmpDir))

    // Real Swift file in Sources
    let realSwift = tmpDir.appendingPathComponent("Sources/Real.swift")
    try fm.createDirectory(at: realSwift.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("// swift".utf8).write(to: realSwift)

    #expect(SwiftLanguage.hasSources(in: tmpDir))

    // TypeScript file in node_modules or .d.ts should NOT count as sources
    let nodeModulesTs = tmpDir.appendingPathComponent("node_modules/react/index.ts")
    try fm.createDirectory(at: nodeModulesTs.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("// ts".utf8).write(to: nodeModulesTs)

    let dtsFile = tmpDir.appendingPathComponent("types/globals.d.ts")
    try fm.createDirectory(at: dtsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("// dts".utf8).write(to: dtsFile)

    #expect(!TypeScriptLanguage.hasSources(in: tmpDir))

    // Real TS file
    let realTs = tmpDir.appendingPathComponent("src/app.ts")
    try fm.createDirectory(at: realTs.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("// ts".utf8).write(to: realTs)

    #expect(TypeScriptLanguage.hasSources(in: tmpDir))
  }
}
