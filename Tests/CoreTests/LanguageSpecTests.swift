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

    let discovered = RepoLocator.withRepoRoot(tmpDir) {
      let inputs = SwiftLanguage.discoverAnalysisInputs()
      return SwiftLanguage.makeConfig(from: inputs) as? SwiftLanguage.Config
    }
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

    let config = TypeScriptLanguage.Config(tsconfig: "tsconfig.json")
    #expect(config.tsconfig == "tsconfig.json")

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

    let discovered = RepoLocator.withRepoRoot(tmpDir) {
      let inputs = TypeScriptLanguage.discoverAnalysisInputs()
      return TypeScriptLanguage.makeUnitConfig(from: inputs.first ?? "") as? TypeScriptLanguage.Config
    }
    #expect(discovered != nil)
    #expect(discovered?.tsconfig == "packages/api/tsconfig.json" || discovered?.tsconfig == "tsconfig.json")
  }

  @Test("ASTConfig type-safe subscripting and configuration state")
  func astConfigSubscripting() {
    var ast = ASTConfig()
    #expect(ast.isEmpty)
    #expect(!ast.isConfigured(.swift))
    #expect(!ast.isConfigured(.ts))
    #expect(ast[SwiftLanguage.self].isEmpty)
    #expect(ast[TypeScriptLanguage.self].isEmpty)

    // Set Swift config
    ast[SwiftLanguage.self] = ["ios": SwiftLanguage.Config(indexStore: "DataStore")]
    #expect(!ast.isEmpty)
    #expect(ast.isConfigured(.swift))
    #expect(!ast.isConfigured(.ts))
    #expect(ast[SwiftLanguage.self]["ios"]?.indexStore == "DataStore")

    // Set TypeScript config
    ast[TypeScriptLanguage.self] = ["web": TypeScriptLanguage.Config(tsconfig: "web/tsconfig.json")]
    #expect(ast.isConfigured(.swift))
    #expect(ast.isConfigured(.ts))
    #expect(ast[TypeScriptLanguage.self]["web"]?.tsconfig == "web/tsconfig.json")

    // Remove Swift config via subscript
    ast[SwiftLanguage.self] = [:]
    #expect(!ast.isConfigured(.swift))
    #expect(ast.isConfigured(.ts))
    #expect(ast[SwiftLanguage.self].isEmpty)

    // Polymorphic subscripting by SupportedLanguage
    ast[.swift] = ["vapor": SwiftLanguage.Config(indexStore: "VaporStore")]
    #expect(ast.isConfigured(.swift))
    let swiftCfg = ast[.swift]["vapor"] as? SwiftLanguage.Config
    #expect(swiftCfg?.indexStore == "VaporStore")

    ast[.swift] = [:]
    #expect(!ast.isConfigured(.swift))
    #expect(ast[.swift].isEmpty)
  }

  @Test("ASTConfig JSON serialization round-trip")
  func astConfigCodable() throws {
    var original = ASTConfig()
    original[SwiftLanguage.self] = [
      "ios": SwiftLanguage.Config(indexStore: "ios/Index/DataStore"),
      "vapor": SwiftLanguage.Config(indexStore: "vapor/.build/debug/index/store"),
    ]
    original[TypeScriptLanguage.self] = [
      "bff": TypeScriptLanguage.Config(tsconfig: "bff/tsconfig.json"),
      "web": TypeScriptLanguage.Config(tsconfig: "web/tsconfig.json"),
    ]

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(ASTConfig.self, from: data)

    #expect(decoded == original)
    #expect(decoded[SwiftLanguage.self]["ios"]?.indexStore == "ios/Index/DataStore")
    #expect(decoded[SwiftLanguage.self]["vapor"]?.indexStore == "vapor/.build/debug/index/store")
    #expect(decoded[TypeScriptLanguage.self]["bff"]?.tsconfig == "bff/tsconfig.json")
    #expect(decoded[TypeScriptLanguage.self]["web"]?.tsconfig == "web/tsconfig.json")
  }

  @Test("Default unit name inference from paths and collision handling")
  func defaultUnitNameInference() {
    // Root level inputs
    #expect(SwiftLanguage.inferDefaultUnitName(for: "build/Index.noindex/DataStore") == "main")
    #expect(SwiftLanguage.inferDefaultUnitName(for: ".build/debug/index/store") == "main")
    #expect(TypeScriptLanguage.inferDefaultUnitName(for: "tsconfig.json") == "main")
    #expect(TypeScriptLanguage.inferDefaultUnitName(for: "tsconfig.base.json") == "main")

    // Nested inputs
    #expect(SwiftLanguage.inferDefaultUnitName(for: "ios/build/Index.noindex/DataStore") == "ios")
    #expect(SwiftLanguage.inferDefaultUnitName(for: "vapor/.build/debug/index/store") == "vapor")
    #expect(TypeScriptLanguage.inferDefaultUnitName(for: "web/tsconfig.json") == "web")
    #expect(TypeScriptLanguage.inferDefaultUnitName(for: "bff/tsconfig.json") == "bff")
    #expect(TypeScriptLanguage.inferDefaultUnitName(for: "apps/web/tsconfig.json") == "web")
    #expect(TypeScriptLanguage.inferDefaultUnitName(for: "packages/api/tsconfig.json") == "api")

    // Collision handling
    #expect(TypeScriptLanguage.inferDefaultUnitName(for: "web/tsconfig.json", existingNames: ["web"]) == "web_2")
    #expect(
      TypeScriptLanguage.inferDefaultUnitName(for: "web/tsconfig.json", existingNames: ["web", "web_2"]) == "web_3")
  }

  @Test("Multi-input discovery across subdirectories")
  func multiInputDiscovery() throws {
    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    // Swift inputs: ios and vapor
    let iosStore = tmpDir.appendingPathComponent("ios/build/Index.noindex/DataStore")
    try fm.createDirectory(at: iosStore, withIntermediateDirectories: true)
    let vaporStore = tmpDir.appendingPathComponent("vapor/build/Index.noindex/DataStore")
    try fm.createDirectory(at: vaporStore, withIntermediateDirectories: true)

    // TS inputs: web and bff
    let webDir = tmpDir.appendingPathComponent("web")
    try fm.createDirectory(at: webDir, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: webDir.appendingPathComponent("tsconfig.json"))
    let bffDir = tmpDir.appendingPathComponent("bff")
    try fm.createDirectory(at: bffDir, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: bffDir.appendingPathComponent("tsconfig.json"))

    RepoLocator.withRepoRoot(tmpDir) {
      let swiftInputs = SwiftLanguage.discoverAnalysisInputs()
      #expect(swiftInputs.contains("ios/build/Index.noindex/DataStore"))
      #expect(swiftInputs.contains("vapor/build/Index.noindex/DataStore"))

      let tsInputs = TypeScriptLanguage.discoverAnalysisInputs()
      #expect(tsInputs.contains("bff/tsconfig.json"))
      #expect(tsInputs.contains("web/tsconfig.json"))
    }
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

    try RepoLocator.withRepoRoot(tmpDir) {
      #expect(!SwiftLanguage.hasSources())
      #expect(!TypeScriptLanguage.hasSources())

      // Add Swift file
      let swiftFile = tmpDir.appendingPathComponent("main.swift")
      try Data("print(1)".utf8).write(to: swiftFile)
      #expect(SwiftLanguage.hasSources())
      #expect(!TypeScriptLanguage.hasSources())

      // Add TS file
      let tsFile = tmpDir.appendingPathComponent("index.ts")
      try Data("console.log(1)".utf8).write(to: tsFile)
      #expect(SwiftLanguage.hasSources())
      #expect(TypeScriptLanguage.hasSources())
    }
  }
}

extension LanguageSpecTests {
  @Test(
    "describeConfig returns fallback for unconfigured projects across all languages",
    arguments: SupportedLanguage.allCases
  )
  func describeConfigOutputs(language: SupportedLanguage) {
    let ast = ASTConfig()
    #expect(language.spec.describeConfig(in: ast) == "none")
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

    let files = RepoLocator.withRepoRoot(repoURL) {
      language.spec.devWorkspaceFiles(environment: env)
    }
    #expect(!files.isEmpty)
    for file in files {
      #expect(!file.relativePath.isEmpty)
      #expect(!file.content.isEmpty)
    }
  }

  @Test("SwiftLanguage discoverAnalysisInputs finds index stores and build output directories")
  func swiftDiscoverAnalysisInputs() throws {
    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let candidateDir = tmpDir.appendingPathComponent("build/Index.noindex/DataStore")
    try fm.createDirectory(at: candidateDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    let candidates = RepoLocator.withRepoRoot(tmpDir) {
      SwiftLanguage.discoverAnalysisInputs()
    }
    #expect(candidates.contains("build/Index.noindex/DataStore"))
  }

  @Test("TypeScriptLanguage discoverAnalysisInputs finds tsconfig.json files")
  func tsDiscoverAnalysisInputs() throws {
    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    let rootTsconfig = tmpDir.appendingPathComponent("tsconfig.json")
    try Data("{}".utf8).write(to: rootTsconfig)

    let pkgTsconfigDir = tmpDir.appendingPathComponent("packages/api")
    try fm.createDirectory(at: pkgTsconfigDir, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: pkgTsconfigDir.appendingPathComponent("tsconfig.json"))

    let candidates = RepoLocator.withRepoRoot(tmpDir) {
      TypeScriptLanguage.discoverAnalysisInputs()
    }
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
    #expect(!descriptor.noInputsFoundMessage.isEmpty)
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

  @Test("Polymorphic discoverAnalysisInputs and makeConfig on AnyLanguageSpec")
  func polymorphicAutoDiscover() async throws {
    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(
      at: tmpDir.appendingPathComponent("build/Index.noindex/DataStore"),
      withIntermediateDirectories: true
    )
    try Data("{}".utf8).write(to: tmpDir.appendingPathComponent("tsconfig.json"))
    defer { try? fm.removeItem(at: tmpDir) }

    RepoLocator.withRepoRoot(tmpDir) {
      let swiftInputs = SupportedLanguage.swift.spec.discoverAnalysisInputs()
      let swiftConfig = SupportedLanguage.swift.spec.makeConfig(from: swiftInputs)
      #expect(swiftConfig != nil)
      #expect((swiftConfig as? SwiftLanguage.Config)?.indexStore == "build/Index.noindex/DataStore")

      let tsInputs = SupportedLanguage.ts.spec.discoverAnalysisInputs()
      let tsConfig = SupportedLanguage.ts.spec.makeConfig(from: tsInputs)
      #expect(tsConfig != nil)
      #expect((tsConfig as? TypeScriptLanguage.Config)?.tsconfig.contains("tsconfig.json") == true)
    }
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

    try RepoLocator.withRepoRoot(tmpDir) {
      // Initially empty
      #expect(!SwiftLanguage.hasSources())
      #expect(!TypeScriptLanguage.hasSources())

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

      #expect(!SwiftLanguage.hasSources())

      // Real Swift file in Sources
      let realSwift = tmpDir.appendingPathComponent("Sources/Real.swift")
      try fm.createDirectory(at: realSwift.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("// swift".utf8).write(to: realSwift)

      #expect(SwiftLanguage.hasSources())

      // TypeScript file in node_modules, kits, or .d.ts should NOT count as sources
      let kitsTs = tmpDir.appendingPathComponent("kits/kit-ts/src/runner.ts")
      try fm.createDirectory(at: kitsTs.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("// ts".utf8).write(to: kitsTs)

      let nodeModulesTs = tmpDir.appendingPathComponent("node_modules/react/index.ts")
      try fm.createDirectory(at: nodeModulesTs.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("// ts".utf8).write(to: nodeModulesTs)

      let dtsFile = tmpDir.appendingPathComponent("types/globals.d.ts")
      try fm.createDirectory(at: dtsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("// dts".utf8).write(to: dtsFile)

      #expect(!TypeScriptLanguage.hasSources())

      // Real TS file
      let realTs = tmpDir.appendingPathComponent("src/app.ts")
      try fm.createDirectory(at: realTs.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("// ts".utf8).write(to: realTs)

      #expect(TypeScriptLanguage.hasSources())
    }
  }

  @Test("invariants repository root detects only Swift sources and skips kits")
  func invariantsRepoRootDetectsOnlySwift() {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    RepoLocator.withRepoRoot(repoRoot) {
      #expect(SwiftLanguage.hasSources())
      #expect(!TypeScriptLanguage.hasSources())
    }
  }
}
