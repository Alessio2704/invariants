import Foundation
import Testing

@testable import InvariantCore

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

  @Test("LanguageCLIParser parses valid language configurations into ProjectConfig")
  func languageCLIParserValid() throws {
    var project = ProjectConfig()

    try LanguageCLIParser.apply(entry: "swift.indexStore=build/MyDataStore", into: &project)
    #expect(project[SwiftLanguage.self]?.indexStore == "build/MyDataStore")

    try LanguageCLIParser.apply(
      entry: "ts.tsconfig=tsconfig.json,packages/core/tsconfig.json",
      into: &project
    )
    #expect(project[TypeScriptLanguage.self]?.tsconfig == ["tsconfig.json", "packages/core/tsconfig.json"])

    // Overwrite existing configuration
    try LanguageCLIParser.apply(entry: "swift.indexStore=build_sim/NewStore", into: &project)
    #expect(project[SwiftLanguage.self]?.indexStore == "build_sim/NewStore")
  }

  @Test("LanguageCLIParser rejects malformed entries with LanguageError and suggestions")
  func languageCLIParserErrors() {
    var project = ProjectConfig()

    #expect(throws: LanguageError.invalidCLIFormat("no_equals_sign")) {
      try LanguageCLIParser.apply(entry: "no_equals_sign", into: &project)
    }

    #expect(throws: LanguageError.invalidCLIFormat("no_dot_target=value")) {
      try LanguageCLIParser.apply(entry: "no_dot_target=value", into: &project)
    }

    #expect(throws: LanguageError.unknownLanguage("rust", suggestion: nil)) {
      try LanguageCLIParser.apply(entry: "rust.manifest=Cargo.toml", into: &project)
    }

    #expect(throws: LanguageError.unknownLanguage("typescript", suggestion: "ts")) {
      try LanguageCLIParser.apply(entry: "typescript.tsconfig=tsconfig.json", into: &project)
    }

    #expect(
      throws: LanguageError.unsupportedField(
        language: "swift",
        field: "tsconfig",
        expected: ["indexStore"],
        suggestion: nil
      )
    ) {
      try LanguageCLIParser.apply(entry: "swift.tsconfig=tsconfig.json", into: &project)
    }

    #expect(
      throws: LanguageError.unsupportedField(
        language: "ts",
        field: "config",
        expected: ["tsconfig"],
        suggestion: "tsconfig"
      )
    ) {
      try LanguageCLIParser.apply(entry: "ts.config=tsconfig.json", into: &project)
    }
  }

  @Test("LanguageCLIParser helpDiscussion details all supported languages and syntax")
  func helpDiscussionContent() {
    let discussion = LanguageCLIParser.helpDiscussion
    for language in SupportedLanguage.allCases {
      #expect(discussion.contains("\(language.rawValue) (\(language.spec.displayName)):"))
      for example in language.spec.fieldExamples {
        #expect(discussion.contains(example))
      }
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

  @Test("SwiftLanguage configureInteractively with discovered candidates")
  func swiftConfigureInteractivelyWithCandidates() throws {
    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let candidateDir = tmpDir.appendingPathComponent("build/Index.noindex/DataStore")
    try fm.createDirectory(at: candidateDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    var config = ProjectConfig()
    let prompter = TestPrompter(promptResponses: ["1"])
    SwiftLanguage.configureInteractively(repoRootURL: tmpDir, prompter: prompter, into: &config)

    #expect(config[SwiftLanguage.self]?.indexStore == "build/Index.noindex/DataStore")
  }

  @Test("SwiftLanguage configureInteractively without candidates prompts for manual input")
  func swiftConfigureInteractivelyWithoutCandidates() throws {
    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    var config = ProjectConfig()
    let prompter = TestPrompter(promptResponses: ["custom/DataStore"])
    SwiftLanguage.configureInteractively(repoRootURL: tmpDir, prompter: prompter, into: &config)

    #expect(config[SwiftLanguage.self]?.indexStore == "custom/DataStore")
    #expect(
      prompter.printedLines.contains(where: {
        $0.contains("Swift sources detected, but no index store candidate was found")
      })
    )
  }

  @Test("TypeScriptLanguage configureInteractively with discovered candidates")
  func tsConfigureInteractivelyWithCandidates() throws {
    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    let tsconfig = tmpDir.appendingPathComponent("tsconfig.json")
    try Data("{}".utf8).write(to: tsconfig)

    var config = ProjectConfig()
    let prompter = TestPrompter(confirmResponses: [true])
    TypeScriptLanguage.configureInteractively(repoRootURL: tmpDir, prompter: prompter, into: &config)

    #expect(config[TypeScriptLanguage.self]?.tsconfig == ["tsconfig.json"])
  }

  @Test("TypeScriptLanguage configureInteractively without candidates prompts for manual input")
  func tsConfigureInteractivelyWithoutCandidates() throws {
    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    var config = ProjectConfig()
    let prompter = TestPrompter(promptResponses: ["custom/tsconfig.json"])
    TypeScriptLanguage.configureInteractively(repoRootURL: tmpDir, prompter: prompter, into: &config)

    #expect(config[TypeScriptLanguage.self]?.tsconfig == ["custom/tsconfig.json"])
    #expect(
      prompter.printedLines.contains(where: {
        $0.contains("TypeScript sources detected, but no tsconfig.json candidate was found.")
      })
    )
  }

  @Test("Non-interactive configureInteractively auto-selects discovered candidate")
  func nonInteractiveConfigureInteractively() throws {
    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let candidateDir = tmpDir.appendingPathComponent("build/Index.noindex/DataStore")
    try fm.createDirectory(at: candidateDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    var config = ProjectConfig()
    SwiftLanguage.configureInteractively(repoRootURL: tmpDir, prompter: nil, into: &config)
    #expect(config[SwiftLanguage.self]?.indexStore == "build/Index.noindex/DataStore")
  }
}

private final class TestPrompter: InteractivePrompter, @unchecked Sendable {
  var promptResponses: [String]
  var confirmResponses: [Bool]
  var printedLines: [String] = []

  init(promptResponses: [String] = [], confirmResponses: [Bool] = []) {
    self.promptResponses = promptResponses
    self.confirmResponses = confirmResponses
  }

  func prompt(question: String) -> String {
    printedLines.append(question)
    return promptResponses.isEmpty ? "" : promptResponses.removeFirst()
  }

  func prompt(question: String, default defaultValue: String?) -> String {
    printedLines.append(question)
    return promptResponses.isEmpty ? (defaultValue ?? "") : promptResponses.removeFirst()
  }

  func promptConfirmation(question: String, default defaultYes: Bool) -> Bool {
    printedLines.append(question)
    return confirmResponses.isEmpty ? defaultYes : confirmResponses.removeFirst()
  }

  func printLine(_ message: String) {
    printedLines.append(message)
  }
}
