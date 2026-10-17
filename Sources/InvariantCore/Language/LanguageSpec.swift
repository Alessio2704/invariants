public import Foundation

/// The set of target languages supported by Invariants for static analysis and rule enforcement.
public enum SupportedLanguage: String, Sendable, Codable, CaseIterable {
  case swift
  case ts

  public var spec: any AnyLanguageSpec.Type {
    switch self {
    case .swift: return SwiftLanguage.self
    case .ts: return TypeScriptLanguage.self
    }
  }
}

/// Typealias preserving target terminology across manifest models.
public typealias TargetLanguage = SupportedLanguage

/// Errors raised during dynamic language configuration and CLI parsing.
public enum LanguageError: Error, Equatable, Sendable, CustomStringConvertible {
  case invalidCLIFormat(String)
  case unknownLanguage(String, suggestion: String? = nil)
  case unsupportedField(language: String, field: String, expected: [String], suggestion: String? = nil)

  public var description: String {
    switch self {
    case .invalidCLIFormat(let entry):
      return "Invalid format '\(entry)'. Expected <language>.<field>=<value> (e.g. swift.indexStore=build/DataStore)"
    case .unknownLanguage(let lang, let suggestion):
      let supported = SupportedLanguage.allCases.map(\.rawValue).joined(separator: ", ")
      if let suggestion {
        return "Unknown language '\(lang)'. Did you mean '\(suggestion)'? Supported languages: \(supported)"
      }
      return "Unknown language '\(lang)'. Supported languages: \(supported)"
    case .unsupportedField(let lang, let field, let expected, let suggestion):
      let expectedList = expected.joined(separator: ", ")
      if let suggestion {
        return
          "Unknown field '\(field)' for language '\(lang)'. Did you mean '\(suggestion)'? Supported fields: \(expectedList)"
      }
      return "Unknown field '\(field)' for language '\(lang)'. Supported fields: \(expectedList)"
    }
  }
}

/// Represents an editor/IDE development file to scaffold in `invariants/.dev/`.
public struct DevWorkspaceFile: Sendable, Equatable {
  public var relativePath: String
  public var content: String

  public init(relativePath: String, content: String) {
    self.relativePath = relativePath
    self.content = content
  }
}

/// Dynamic contract for language specifications supporting discovery, interactive configuration, and CLI parsing.
public protocol AnyLanguageSpec: Sendable {
  static var language: SupportedLanguage { get }
  static var displayName: String { get }
  static var ruleFileName: String { get }
  static var fieldExamples: [String] { get }
  static var executionSpec: RuleExecutionSpec { get }

  /// Detects if this language has source files in the repository.
  static func hasSources(in repoRoot: URL) -> Bool

  /// Returns a human-readable description of this language's configured inputs.
  static func describeConfig(in project: ProjectConfig) -> String

  /// Applies a CLI key-value setting (e.g. key: "indexStore", value: "build/DataStore") to `project`.
  static func applyCLI(field: String, value: String, into project: inout ProjectConfig) throws(LanguageError)

  /// Returns editor/IDE development files to scaffold in `invariants/.dev/` for authoring rules in this language.
  static func devWorkspaceFiles(repoRootURL: URL, environment: SystemEnvironment) -> [DevWorkspaceFile]
}

/// Contract for a supported language specification, binding language identity to its compile-time configuration schema.
public protocol LanguageSpec: AnyLanguageSpec {
  /// The strongly-typed project configuration schema required by this language.
  associatedtype Config: Sendable, Equatable, Codable
}

/// Swift language specification requiring an Apple / Clang index store.
public struct SwiftLanguage: LanguageSpec {
  public static let language = SupportedLanguage.swift
  public static let displayName = "Swift"
  public static let sourceExtensions = ["swift"]
  public static let ruleFileName = "rule.swift"
  public static let supportedFields = ["indexStore"]
  public static let fieldExamples = [
    "indexStore=<path>  (e.g. swift.indexStore=build/Index.noindex/DataStore)"
  ]
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
  public struct Config: Sendable, Equatable, Codable {
    public var indexStore: String

    public init(indexStore: String) {
      self.indexStore = indexStore
    }
  }

  public static func hasSources(in repoRoot: URL) -> Bool {
    hasFiles(in: repoRoot, matchingExtensions: sourceExtensions)
  }

  public static func describeConfig(in project: ProjectConfig) -> String {
    project[Self.self]?.indexStore ?? "none"
  }

  public static func applyCLI(field: String, value: String, into project: inout ProjectConfig) throws(LanguageError) {
    guard field == "indexStore" else {
      let suggestion = LanguageCLIParser.suggestField(for: field, language: .swift)
      throw LanguageError.unsupportedField(
        language: language.rawValue,
        field: field,
        expected: supportedFields,
        suggestion: suggestion
      )
    }
    project[Self.self] = Config(indexStore: value)
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
}

/// TypeScript language specification requiring one or more tsconfig.json configurations.
public struct TypeScriptLanguage: LanguageSpec {
  public static let language = SupportedLanguage.ts
  public static let displayName = "TypeScript"
  public static let ruleFileName = "rule.ts"
  public static let sourceExtensions = ["ts", "tsx", "js", "jsx"]
  public static let supportedFields = ["tsconfig"]
  public static let fieldExamples = [
    "tsconfig=<paths>  (comma-separated, e.g. ts.tsconfig=tsconfig.json)"
  ]
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
  public struct Config: Sendable, Equatable, Codable {
    public var tsconfig: [String]

    public init(tsconfig: [String]) {
      self.tsconfig = tsconfig
    }
  }

  public static func hasSources(in repoRoot: URL) -> Bool {
    hasFiles(in: repoRoot, matchingExtensions: sourceExtensions)
  }

  public static func describeConfig(in project: ProjectConfig) -> String {
    let list = project[Self.self]?.tsconfig ?? []
    return list.isEmpty ? "none" : list.joined(separator: ", ")
  }

  public static func applyCLI(field: String, value: String, into project: inout ProjectConfig) throws(LanguageError) {
    guard field == "tsconfig" else {
      let suggestion = LanguageCLIParser.suggestField(for: field, language: .ts)
      throw LanguageError.unsupportedField(
        language: language.rawValue,
        field: field,
        expected: supportedFields,
        suggestion: suggestion
      )
    }
    let paths = value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    project[Self.self] = Config(tsconfig: paths)
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
}

/// Dynamic CLI parser and help generator for language configuration options.
public enum LanguageCLIParser {
  /// Formatted discussion detailing each supported language and its fields for CLI `--help`.
  public static var helpDiscussion: String {
    var lines: [String] = [
      "Configure compiler analysis inputs for supported languages in <lang>.<field>=<value> format:\n"
    ]
    for lang in SupportedLanguage.allCases {
      lines.append("  • \(lang.rawValue) (\(lang.spec.displayName)):")
      for ex in lang.spec.fieldExamples {
        lines.append("      \(ex)")
      }
    }
    return lines.joined(separator: "\n")
  }

  /// Suggests a canonical language identifier for common typos or aliases.
  public static func suggestLanguage(for input: String) -> String? {
    let lower = input.lowercased()
    switch lower {
    case "typescript", "types", "tsc", "javascript", "js":
      return "ts"
    case "swfit", "apple":
      return "swift"
    default:
      return nil
    }
  }

  /// Suggests a valid field name for common typos within a language.
  public static func suggestField(for field: String, language: SupportedLanguage) -> String? {
    let lower = field.lowercased()
    switch language {
    case .swift:
      if lower.contains("index") || lower.contains("store") || lower.contains("datastore") {
        return "indexStore"
      }
    case .ts:
      if lower.contains("config") || lower.contains("tsconfig") || lower.contains("project") {
        return "tsconfig"
      }
    }
    return nil
  }

  /// Parses and applies `<language>.<field>=<value>` into `ProjectConfig`.
  public static func apply(entry: String, into project: inout ProjectConfig) throws(LanguageError) {
    let parts = entry.split(separator: "=", maxSplits: 1)
    guard parts.count == 2 else {
      throw LanguageError.invalidCLIFormat(entry)
    }
    let target = parts[0].split(separator: ".", maxSplits: 1)
    guard target.count == 2 else {
      throw LanguageError.invalidCLIFormat(entry)
    }
    let langRaw = String(target[0]).lowercased()
    let field = String(target[1])
    let value = String(parts[1]).trimmingCharacters(in: .whitespaces)

    guard let lang = SupportedLanguage(rawValue: langRaw) else {
      let suggestion = suggestLanguage(for: langRaw)
      throw LanguageError.unknownLanguage(langRaw, suggestion: suggestion)
    }

    try lang.spec.applyCLI(field: field, value: value, into: &project)
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
