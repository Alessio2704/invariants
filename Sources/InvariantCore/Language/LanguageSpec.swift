public import Foundation

/// The set of target languages supported by Invariants for static analysis and rule enforcement.
public enum SupportedLanguage: String, CodingKey, Sendable, Codable, CaseIterable {
  case swift
  case ts

  public var stringValue: String { rawValue }
  public init?(stringValue: String) { self.init(rawValue: stringValue) }
  public var intValue: Int? { nil }
  public init?(intValue: Int) { nil }

  public var spec: any AnyLanguageSpec.Type {
    switch self {
    case .swift: return SwiftLanguage.self
    case .ts: return TypeScriptLanguage.self
    }
  }
}

/// Typealias preserving target terminology across manifest models.
public typealias TargetLanguage = SupportedLanguage

/// Represents an editor/IDE development file to scaffold in `invariants/.dev/`.
public struct DevWorkspaceFile: Sendable, Equatable {
  public var relativePath: String
  public var content: String

  public init(relativePath: String, content: String) {
    self.relativePath = relativePath
    self.content = content
  }
}

/// Dynamic contract for a language's strongly-typed compile-time configuration.
public protocol LanguageConfiguration: Sendable, Codable {
  func isEqualTo(_ other: any LanguageConfiguration) -> Bool
  func toCanonicalJSON() -> String?
}

extension LanguageConfiguration where Self: Equatable {
  public func isEqualTo(_ other: any LanguageConfiguration) -> Bool {
    guard let otherTyped = other as? Self else { return false }
    return self == otherTyped
  }

  public func toCanonicalJSON() -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(self) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}

/// Dynamic contract for language specifications supporting discovery and interactive configuration.
public protocol AnyLanguageSpec: Sendable {
  static var language: SupportedLanguage { get }
  static var displayName: String { get }
  static var sourceExtensions: [String] { get }
  static var ruleFileName: String { get }
  static var executionSpec: RuleExecutionSpec { get }

  /// Decodes this language's configuration polymorphically from a decoder.
  static func decodeConfig(from decoder: any Decoder) throws -> (any LanguageConfiguration)?

  /// Encodes this language's configuration polymorphically to an encoder.
  static func encodeConfig(_ config: any LanguageConfiguration, to encoder: any Encoder) throws

  /// Detects if this language has source files in the repository.
  static func hasSources(in repoRoot: URL) -> Bool

  /// Returns a human-readable description of this language's configured inputs.
  static func describeConfig(in project: ProjectConfig) -> String

  /// Returns editor/IDE development files to scaffold in `invariants/.dev/` for authoring rules in this language.
  static func devWorkspaceFiles(repoRootURL: URL, environment: SystemEnvironment) -> [DevWorkspaceFile]

  /// Interactively configures project inputs for this language if sources are detected.
  static func configureInteractively(
    repoRootURL: URL,
    prompter: (any InteractivePrompter)?,
    into projectConfig: inout ProjectConfig
  )
}

extension AnyLanguageSpec {
  public static func hasSources(in repoRoot: URL) -> Bool {
    hasFiles(in: repoRoot, matchingExtensions: sourceExtensions)
  }
}

/// Contract for a supported language specification, binding language identity to its compile-time configuration schema.
public protocol LanguageSpec: AnyLanguageSpec {
  /// The strongly-typed project configuration schema required by this language.
  associatedtype Config: LanguageConfiguration, Equatable
}

extension LanguageSpec {
  public static func decodeConfig(from decoder: any Decoder) throws -> (any LanguageConfiguration)? {
    try Config(from: decoder)
  }

  public static func encodeConfig(_ config: any LanguageConfiguration, to encoder: any Encoder) throws {
    guard let typed = config as? Config else { return }
    try typed.encode(to: encoder)
  }
}

/// Swift language specification requiring an Apple / Clang index store.
public enum SwiftLanguage: LanguageSpec {
  public static let language = SupportedLanguage.swift
  public static let displayName = "Swift"
  public static let sourceExtensions = ["swift"]
  public static let ruleFileName = "rule.swift"
  public static let executionSpec = RuleExecutionSpec(
    model: .compiled(
      CompiledSpec(
        buildToolchain: .xcrun,
        buildArguments: ["swift", "build"],
        kitPackageName: "kit-swift",
        artifactRelativePath: ".build/release/RuleExecutable",
        debugArtifactRelativePath: ".build/debug/RuleExecutable",
        sourceExtensions: ["swift"],
        manifestKind: .swiftPackage(
          toolsVersion: "6.0",
          targetName: "RuleExecutable",
          productName: "InvariantKit"
        )
      )
    ),
    reporting: RuleReportingProtocol(
      channel: .stdoutJSON,
      successExitCode: 0,
      staleIndexExitCode: 2,
      staleIndexStderrMarker: "INDEX STALE"
    )
  )

  /// Swift requires a single index store path for IndexStoreDB / symbol graph analysis.
  public struct Config: LanguageConfiguration, Equatable {
    public var indexStore: String

    public init(indexStore: String) {
      self.indexStore = indexStore
    }

    public func toCanonicalJSON() -> String? {
      "{ \"indexStore\": \"\(CanonicalJSON.escape(indexStore))\" }"
    }
  }

  public static func describeConfig(in project: ProjectConfig) -> String {
    project[Self.self]?.indexStore ?? "none"
  }

  public static func discoverCandidates(repoRootURL: URL) -> [String] {
    let fm = FileManager.default
    var candidates: [String] = []
    let rootURL = repoRootURL.resolvingSymlinksInPath()
    let rootPath = rootURL.path

    if let enumerator = fm.enumerator(
      at: rootURL,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) {
      while let fileURL = enumerator.nextObject() as? URL {
        let path = fileURL.resolvingSymlinksInPath().path
        if path.contains("/node_modules/") || path.contains("/.build/") || path.contains("/invariants/.dev/") {
          enumerator.skipDescendants()
          continue
        }
        if path.hasSuffix("Index.noindex/DataStore") {
          guard path.hasPrefix(rootPath) else { continue }
          var rel = String(path.dropFirst(rootPath.count))
          if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
          candidates.append(rel)
        }
      }
    }
    let spmStore = rootURL.appendingPathComponent(".build/debug/index/store")
    if fm.fileExists(atPath: spmStore.path) {
      candidates.append(".build/debug/index/store")
    }
    let spmOut = rootURL.appendingPathComponent(".build/out")
    if fm.fileExists(atPath: spmOut.path) {
      candidates.append(".build/out")
    }
    return Array(Set(candidates)).sorted()
  }

  public static func autoDiscover(repoRoot: URL) async -> Config? {
    let candidates = discoverCandidates(repoRootURL: repoRoot)
    guard let first = candidates.first else { return nil }
    return Config(indexStore: first)
  }

  public static func devWorkspaceFiles(repoRootURL: URL, environment: SystemEnvironment) -> [DevWorkspaceFile] {
    let fm = FileManager.default
    let kitSwiftURL = environment.kitURL(named: "kit-swift")
    let kitSwiftPath = fm.fileExists(atPath: kitSwiftURL.path) ? kitSwiftURL.path : repoRootURL.path
    let kitPackageName =
      URL(fileURLWithPath: kitSwiftPath).lastPathComponent == "kit-swift" ? "kit-swift" : "invariants"

    let devPackage = """
      // swift-tools-version: 6.0
      import PackageDescription

      let package = Package(
          name: "InvariantsDev",
          platforms: [.macOS(.v14)],
          dependencies: [
              .package(path: "\(kitSwiftPath)")
          ],
          targets: [
              .target(
                  name: "InvariantsDev",
                  dependencies: [
                      .product(name: "InvariantKit", package: "\(kitPackageName)")
                  ],
                  path: "."
              )
          ]
      )
      """
    return [DevWorkspaceFile(relativePath: "Package.swift", content: devPackage)]
  }

  public static func configureInteractively(
    repoRootURL: URL,
    prompter: (any InteractivePrompter)?,
    into projectConfig: inout ProjectConfig
  ) {
    let candidates = discoverCandidates(repoRootURL: repoRootURL)
    if let prompter {
      if candidates.isEmpty {
        prompter.printLine(
          "\nSwift sources detected, but no index store candidate was found "
            + "(e.g. build/Index.noindex/DataStore, .build/out, or .build/debug/index/store)."
        )
        let choice = prompter.prompt(question: "Enter index store path (press Enter to skip / configure later)")
        if !choice.isEmpty {
          projectConfig[Self.self] = Config(indexStore: choice)
        }
      } else {
        let options = candidates.map { PromptOption(value: $0, label: $0) }
        if let choice = prompter.promptSelection(
          title: "Discovered Swift Index candidates:",
          options: options,
          default: nil,
          customHandler: { $0 }
        ) {
          projectConfig[Self.self] = Config(indexStore: choice)
        }
      }
    } else {
      if let first = candidates.first {
        projectConfig[Self.self] = Config(indexStore: first)
      }
    }
  }
}

/// TypeScript language specification requiring one or more tsconfig.json configurations.
public enum TypeScriptLanguage: LanguageSpec {
  public static let language = SupportedLanguage.ts
  public static let displayName = "TypeScript"
  public static let ruleFileName = "rule.ts"
  public static let sourceExtensions = ["ts", "tsx", "js", "jsx"]
  public static let executionSpec = RuleExecutionSpec(
    model: .interpreted(
      InterpretedSpec(
        runtimeCommand: "node",
        kitDirectoryName: "kit-ts",
        kitRunnerRelativePath: "dist/runner.js",
        devRunnerRelativePath: "src/runner.ts"
      )
    ),
    reporting: RuleReportingProtocol(
      channel: .stdoutJSON,
      successExitCode: 0,
      staleIndexExitCode: 2,
      staleIndexStderrMarker: "INDEX STALE"
    )
  )

  /// TypeScript requires an array of relative tsconfig.json paths for compiler API / ts-morph.
  public struct Config: LanguageConfiguration, Equatable {
    public var tsconfig: [String]

    public init(tsconfig: [String]) {
      self.tsconfig = tsconfig
    }

    public func toCanonicalJSON() -> String? {
      let formatted = tsconfig.map { "\"\(CanonicalJSON.escape($0))\"" }.joined(separator: ", ")
      return "{ \"tsconfig\": [\(formatted)] }"
    }
  }

  public static func describeConfig(in project: ProjectConfig) -> String {
    let list = project[Self.self]?.tsconfig ?? []
    return list.isEmpty ? "none" : list.joined(separator: ", ")
  }

  public static func discoverCandidates(repoRootURL: URL) -> [String] {
    let fm = FileManager.default
    var candidates: [String] = []
    let rootURL = repoRootURL.resolvingSymlinksInPath()
    let rootPath = rootURL.path

    if let enumerator = fm.enumerator(
      at: rootURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) {
      while let fileURL = enumerator.nextObject() as? URL {
        let path = fileURL.resolvingSymlinksInPath().path
        if path.contains("/node_modules/") || path.contains("/.build/") || path.contains("/invariants/.dev/") {
          enumerator.skipDescendants()
          continue
        }
        let fileName = fileURL.lastPathComponent
        if fileName.hasPrefix("tsconfig") && fileName.hasSuffix(".json") {
          guard path.hasPrefix(rootPath) else { continue }
          var rel = String(path.dropFirst(rootPath.count))
          if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
          candidates.append(rel)
        }
      }
    }
    return candidates.sorted()
  }

  public static func autoDiscover(repoRoot: URL) async -> Config? {
    let candidates = discoverCandidates(repoRootURL: repoRoot)
    guard !candidates.isEmpty else { return nil }
    return Config(tsconfig: candidates)
  }

  public static func devWorkspaceFiles(repoRootURL: URL, environment: SystemEnvironment) -> [DevWorkspaceFile] {
    let devTsconfig = """
      {
        "compilerOptions": {
          "target": "ES2022",
          "module": "NodeNext",
          "moduleResolution": "NodeNext",
          "strict": true
        },
        "include": ["../rules/**/*.ts"]
      }
      """
    return [DevWorkspaceFile(relativePath: "tsconfig.json", content: devTsconfig)]
  }

  public static func configureInteractively(
    repoRootURL: URL,
    prompter: (any InteractivePrompter)?,
    into projectConfig: inout ProjectConfig
  ) {
    let candidates = discoverCandidates(repoRootURL: repoRootURL)
    if let prompter {
      if candidates.isEmpty {
        prompter.printLine("\nTypeScript sources detected, but no tsconfig.json candidate was found.")
        let custom = prompter.prompt(question: "Enter tsconfig relative path (press Enter to skip / configure later)")
        if !custom.isEmpty {
          projectConfig[Self.self] = Config(tsconfig: [custom])
        }
      } else {
        let joined = candidates.joined(separator: ", ")
        let confirm = prompter.promptConfirmation(
          question: "Use discovered tsconfig paths (\(joined))?",
          default: true
        )
        if confirm {
          projectConfig[Self.self] = Config(tsconfig: candidates)
        } else {
          let custom = prompter.prompt(question: "Enter tsconfig relative path (press Enter to skip)")
          if !custom.isEmpty {
            projectConfig[Self.self] = Config(tsconfig: [custom])
          }
        }
      }
    } else {
      if !candidates.isEmpty {
        projectConfig[Self.self] = Config(tsconfig: candidates)
      }
    }
  }
}

private func hasFiles(in rootURL: URL, matchingExtensions: [String]) -> Bool {
  let fm = FileManager.default
  guard
    let enumerator = fm.enumerator(
      at: rootURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    )
  else { return false }

  let exts = Set(matchingExtensions)
  while let fileURL = enumerator.nextObject() as? URL {
    let path = fileURL.path
    let isIgnored =
      path.contains("/node_modules/") || path.contains("/.build/") || path.contains("/build/")
      || path.contains("/invariants/.dev/")
    if isIgnored {
      enumerator.skipDescendants()
      continue
    }
    if exts.contains(fileURL.pathExtension) {
      return true
    }
  }
  return false
}
