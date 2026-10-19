public import Foundation

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
  static func shouldSkip(url: URL) -> Bool

  /// Decodes this language's configuration polymorphically from a decoder.
  static func decodeConfig(from decoder: any Decoder) throws -> (any LanguageConfiguration)?

  /// Encodes this language's configuration polymorphically to an encoder.
  static func encodeConfig(_ config: any LanguageConfiguration, to encoder: any Encoder) throws

  /// Detects if this language has source files in the repository.
  static func hasSources() -> Bool

  /// Discovers candidate analysis input paths for this language in the repository root.
  static func discoverAnalysisInputs() -> [String]

  /// Specification descriptor for interactive terminal configuration prompts.
  static var configPromptDescriptor: LanguageConfigPromptDescriptor { get }

  /// Constructs a configuration instance polymorphically from selected path(s).
  static func makeConfig(from paths: [String]) -> (any LanguageConfiguration)?

  /// Automatically discovers configuration without user intervention.
  static func autoDiscover() async -> (any LanguageConfiguration)?

  /// Returns a human-readable description of this language's configured inputs.
  static func describeConfig(in languages: LanguagesConfig) -> String

  /// Returns editor/IDE development files to scaffold in `invariants/.dev/` for authoring rules in this language.
  static func devWorkspaceFiles(environment: SystemEnvironment) -> [DevWorkspaceFile]
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

  public static func shouldSkip(url: URL) -> Bool {
    let rootPath = RepoLocator.current.standardizedFileURL.path
    let filePath = url.standardizedFileURL.path
    if filePath.hasPrefix(rootPath) {
      var rel = String(filePath.dropFirst(rootPath.count))
      if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
      return shouldSkip(relativePath: rel)
    }
    return shouldSkip(relativePath: url.lastPathComponent)
  }

  public static func hasSources() -> Bool {
    let fm = FileManager.default
    let rootURL = RepoLocator.current.standardizedFileURL
    guard
      let enumerator = fm.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else { return false }

    let exts = Set(sourceExtensions)
    while let fileURL = enumerator.nextObject() as? URL {
      if SupportedLanguage.shouldSkipAny(url: fileURL) {
        enumerator.skipDescendants()
        continue
      }
      if exts.contains(fileURL.pathExtension) {
        return true
      }
    }
    return false
  }

  public static func autoDiscover() async -> (any LanguageConfiguration)? {
    let candidates = discoverAnalysisInputs()
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

/// Contract for a supported language specification, binding language identity to its compile-time configuration schema.
public protocol LanguageSpec: AnyLanguageSpec {
  /// The strongly-typed project configuration schema required by this language.
  associatedtype Config: LanguageConfiguration, Equatable

  /// Strongly-typed automatic discovery.
  static func autoDiscover() async -> Config?
}

extension LanguageSpec {
  public static func decodeConfig(from decoder: any Decoder) throws -> (any LanguageConfiguration)? {
    try Config(from: decoder)
  }

  public static func encodeConfig(_ config: any LanguageConfiguration, to encoder: any Encoder) throws {
    guard let typed = config as? Config else { return }
    try typed.encode(to: encoder)
  }

  public static func autoDiscover() async -> Config? {
    let candidates = discoverAnalysisInputs()
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
