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

/// Declarative specification for interactive terminal configuration prompts and candidate presentation.
public struct LanguageConfigPromptDescriptor: Sendable, Equatable {
  /// Defines how discovered candidates are presented to the user during interactive configuration.
  public enum SelectionStyle: Sendable, Equatable {
    /// Select one candidate from discovered options with an optional custom fallback.
    case single(selectionTitle: String)
    /// Confirm all discovered candidates together, or prompt for a manual custom fallback.
    case multiple(confirmationQuestion: String)
  }

  /// Message printed when no candidates are detected in the repository.
  public var noCandidatesMessage: String
  /// Prompt text when asking the user to manually enter a path when no candidates are found.
  public var manualPromptQuestion: String
  /// Prompt text when asking for a custom path after rejecting discovered candidates.
  public var manualFallbackQuestion: String
  /// How discovered candidates should be presented to the user.
  public var selectionStyle: SelectionStyle

  public init(
    noCandidatesMessage: String,
    manualPromptQuestion: String,
    manualFallbackQuestion: String? = nil,
    selectionStyle: SelectionStyle
  ) {
    self.noCandidatesMessage = noCandidatesMessage
    self.manualPromptQuestion = manualPromptQuestion
    self.manualFallbackQuestion = manualFallbackQuestion ?? manualPromptQuestion
    self.selectionStyle = selectionStyle
  }
}

/// Dynamic contract for language specifications supporting discovery and interactive configuration.
public protocol AnyLanguageSpec: Sendable {
  static var language: SupportedLanguage { get }
  static var displayName: String { get }
  static var sourceExtensions: [String] { get }
  static var ruleFileName: String { get }
  static var executionSpec: RuleExecutionSpec { get }

  /// Subpaths or directory names to skip during file discovery and scans for this language.
  static var defaultIgnoredPaths: [String] { get }

  /// File extensions (e.g. `["d.ts", "map"]`) to skip during file discovery and scans for this language.
  static var defaultIgnoredExtensions: [String] { get }

  /// Matches whether a relative path matches an ignored directory or file pattern.
  static func matchesIgnoredPath(relativePath: String, ignoredPattern: String) -> Bool

  /// Checks if a relative path should be skipped for this language.
  static func shouldSkip(relativePath: String) -> Bool

  /// Checks if a file URL should be skipped for this language.
  static func shouldSkip(url: URL, repoRoot: URL) -> Bool

  /// Decodes this language's configuration polymorphically from a decoder.
  static func decodeConfig(from decoder: any Decoder) throws -> (any LanguageConfiguration)?

  /// Encodes this language's configuration polymorphically to an encoder.
  static func encodeConfig(_ config: any LanguageConfiguration, to encoder: any Encoder) throws

  /// Detects if this language has source files in the repository.
  static func hasSources(in repoRoot: URL) -> Bool

  /// Discovers candidate paths for this language in the given repository root.
  static func discoverCandidates(repoRootURL: URL) -> [String]

  /// Specification descriptor for interactive terminal configuration prompts.
  static var configPromptDescriptor: LanguageConfigPromptDescriptor { get }

  /// Constructs a configuration instance polymorphically from selected path(s).
  static func makeConfig(from paths: [String]) -> (any LanguageConfiguration)?

  /// Automatically discovers configuration without user intervention.
  static func autoDiscover(repoRoot: URL) async -> (any LanguageConfiguration)?

  /// Returns a human-readable description of this language's configured inputs.
  static func describeConfig(in languages: LanguagesConfig) -> String

  /// Returns editor/IDE development files to scaffold in `invariants/.dev/` for authoring rules in this language.
  static func devWorkspaceFiles(repoRootURL: URL, environment: SystemEnvironment) -> [DevWorkspaceFile]
}

extension AnyLanguageSpec {
  public static var defaultIgnoredPaths: [String] { [] }
  public static var defaultIgnoredExtensions: [String] { [] }

  public static func matchesIgnoredPath(relativePath: String, ignoredPattern: String) -> Bool {
    let normalized = relativePath.hasPrefix("/") ? String(relativePath.dropFirst()) : relativePath
    guard !normalized.isEmpty, !ignoredPattern.isEmpty else { return false }
    if normalized == ignoredPattern { return true }
    if normalized.hasPrefix(ignoredPattern + "/") { return true }
    if normalized.contains("/" + ignoredPattern + "/") { return true }
    if normalized.hasSuffix("/" + ignoredPattern) { return true }
    return false
  }

  public static func shouldSkip(relativePath: String) -> Bool {
    let normalized = relativePath.hasPrefix("/") ? String(relativePath.dropFirst()) : relativePath
    guard !normalized.isEmpty else { return false }

    for universal in SystemPaths.universalIgnoredPaths
    where matchesIgnoredPath(relativePath: normalized, ignoredPattern: universal) {
      return true
    }

    for path in defaultIgnoredPaths
    where matchesIgnoredPath(relativePath: normalized, ignoredPattern: path) {
      return true
    }

    let fileName = URL(fileURLWithPath: normalized).lastPathComponent
    for ext in defaultIgnoredExtensions where fileName.hasSuffix(ext.hasPrefix(".") ? ext : "." + ext) {
      return true
    }

    return false
  }

  public static func shouldSkip(url: URL, repoRoot: URL) -> Bool {
    let rootPath = repoRoot.standardizedFileURL.path
    let filePath = url.standardizedFileURL.path
    if filePath.hasPrefix(rootPath) {
      var rel = String(filePath.dropFirst(rootPath.count))
      if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
      return shouldSkip(relativePath: rel)
    }
    return shouldSkip(relativePath: url.lastPathComponent)
  }

  public static func hasSources(in repoRoot: URL) -> Bool {
    let fm = FileManager.default
    let rootURL = repoRoot.standardizedFileURL
    guard
      let enumerator = fm.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else { return false }

    let exts = Set(sourceExtensions)
    while let fileURL = enumerator.nextObject() as? URL {
      if SupportedLanguage.shouldSkipAny(url: fileURL, repoRoot: rootURL) {
        enumerator.skipDescendants()
        continue
      }
      if exts.contains(fileURL.pathExtension) {
        return true
      }
    }
    return false
  }

  public static func autoDiscover(repoRoot: URL) async -> (any LanguageConfiguration)? {
    let candidates = discoverCandidates(repoRootURL: repoRoot)
    guard !candidates.isEmpty else { return nil }
    switch configPromptDescriptor.selectionStyle {
    case .single:
      guard let first = candidates.first else { return nil }
      return makeConfig(from: [first])
    case .multiple:
      return makeConfig(from: candidates)
    }
  }
}

extension SupportedLanguage {
  /// Aggregates all default ignored paths across all supported languages and universal system paths.
  public static var allDefaultIgnoredPaths: [String] {
    let languagePaths = allCases.flatMap { $0.spec.defaultIgnoredPaths }
    return Array(Set(SystemPaths.universalIgnoredPaths + languagePaths)).sorted()
  }

  /// Aggregates all default ignored extensions across all supported languages.
  public static var allDefaultIgnoredExtensions: [String] {
    Array(Set(allCases.flatMap { $0.spec.defaultIgnoredExtensions })).sorted()
  }

  /// Checks if a relative path should be skipped across any supported language or universal system path.
  public static func shouldSkipAny(relativePath: String) -> Bool {
    for universal in SystemPaths.universalIgnoredPaths
    where SwiftLanguage.matchesIgnoredPath(relativePath: relativePath, ignoredPattern: universal) {
      return true
    }
    return allCases.contains { $0.spec.shouldSkip(relativePath: relativePath) }
  }

  /// Checks if a file URL should be skipped across any supported language or universal system path.
  public static func shouldSkipAny(url: URL, repoRoot: URL) -> Bool {
    allCases.contains { $0.spec.shouldSkip(url: url, repoRoot: repoRoot) }
  }
}

/// Contract for a supported language specification, binding language identity to its compile-time configuration schema.
public protocol LanguageSpec: AnyLanguageSpec {
  /// The strongly-typed project configuration schema required by this language.
  associatedtype Config: LanguageConfiguration, Equatable

  /// Strongly-typed automatic discovery.
  static func autoDiscover(repoRoot: URL) async -> Config?
}

extension LanguageSpec {
  public static func decodeConfig(from decoder: any Decoder) throws -> (any LanguageConfiguration)? {
    try Config(from: decoder)
  }

  public static func encodeConfig(_ config: any LanguageConfiguration, to encoder: any Encoder) throws {
    guard let typed = config as? Config else { return }
    try typed.encode(to: encoder)
  }

  public static func autoDiscover(repoRoot: URL) async -> Config? {
    let candidates = discoverCandidates(repoRootURL: repoRoot)
    guard !candidates.isEmpty else { return nil }
    switch configPromptDescriptor.selectionStyle {
    case .single:
      guard let first = candidates.first else { return nil }
      return makeConfig(from: [first]) as? Config
    case .multiple:
      return makeConfig(from: candidates) as? Config
    }
  }
}

/// Swift language specification requiring an Apple / Clang index store.
public enum SwiftLanguage: LanguageSpec {
  public static let language = SupportedLanguage.swift
  public static let displayName = "Swift"
  public static let sourceExtensions = ["swift"]
  public static let ruleFileName = "rule.swift"
  public static let defaultIgnoredPaths = [".build", "build"]
  public static let defaultIgnoredExtensions: [String] = []
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

  public static func describeConfig(in languages: LanguagesConfig) -> String {
    languages[Self.self]?.indexStore ?? "none"
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
        if SupportedLanguage.shouldSkipAny(url: fileURL, repoRoot: rootURL) {
          if fileURL.lastPathComponent == "build" {
            // Allow searching within build directory for Index.noindex/DataStore
          } else {
            enumerator.skipDescendants()
            continue
          }
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
    let xcodeStore = rootURL.appendingPathComponent("build/Index.noindex/DataStore")
    if fm.fileExists(atPath: xcodeStore.path) {
      candidates.append("build/Index.noindex/DataStore")
    }
    return Array(Set(candidates)).sorted()
  }

  public static let configPromptDescriptor = LanguageConfigPromptDescriptor(
    noCandidatesMessage: "Swift sources detected, but no index store candidate was found "
      + "(e.g. build/Index.noindex/DataStore, .build/out, or .build/debug/index/store).",
    manualPromptQuestion: "Enter index store path (press Enter to skip / configure later)",
    selectionStyle: .single(selectionTitle: "Discovered Swift Index candidates:")
  )

  public static func makeConfig(from paths: [String]) -> (any LanguageConfiguration)? {
    guard let first = paths.first, !first.isEmpty else { return nil }
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
public enum TypeScriptLanguage: LanguageSpec {
  public static let language = SupportedLanguage.ts
  public static let displayName = "TypeScript"
  public static let ruleFileName = "rule.ts"
  public static let sourceExtensions = ["ts", "tsx", "js", "jsx"]
  public static let defaultIgnoredPaths = ["node_modules", "dist"]
  public static let defaultIgnoredExtensions = ["d.ts", "map"]
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

  public static func describeConfig(in languages: LanguagesConfig) -> String {
    let list = languages[Self.self]?.tsconfig ?? []
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
        if SupportedLanguage.shouldSkipAny(url: fileURL, repoRoot: rootURL) {
          enumerator.skipDescendants()
          continue
        }
        let fileName = fileURL.lastPathComponent
        if fileName.hasPrefix("tsconfig") && fileName.hasSuffix(".json") {
          let path = fileURL.resolvingSymlinksInPath().path
          guard path.hasPrefix(rootPath) else { continue }
          var rel = String(path.dropFirst(rootPath.count))
          if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
          candidates.append(rel)
        }
      }
    }
    return candidates.sorted()
  }

  public static let configPromptDescriptor = LanguageConfigPromptDescriptor(
    noCandidatesMessage: "TypeScript sources detected, but no tsconfig.json candidate was found.",
    manualPromptQuestion: "Enter tsconfig relative path (press Enter to skip / configure later)",
    manualFallbackQuestion: "Enter tsconfig relative path (press Enter to skip)",
    selectionStyle: .multiple(confirmationQuestion: "Use discovered tsconfig paths")
  )

  public static func makeConfig(from paths: [String]) -> (any LanguageConfiguration)? {
    let filtered = paths.filter { !$0.isEmpty }
    guard !filtered.isEmpty else { return nil }
    return Config(tsconfig: filtered)
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
