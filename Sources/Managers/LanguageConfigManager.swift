package import Core
package import Foundation

/// Pure domain manager for language analysis candidate discovery and configuration injection.
/// Headless: zero terminal prompting or CLI dependencies.
package enum LanguageConfigManager {
  /// Discovers candidate paths for Swift index store.
  package static func discoverSwiftCandidates(repoRootURL: URL) -> [String] {
    SwiftLanguage.discoverCandidates(repoRootURL: repoRootURL)
  }

  /// Discovers candidate paths for TypeScript tsconfig.json files.
  package static func discoverTypeScriptCandidates(repoRootURL: URL) -> [String] {
    TypeScriptLanguage.discoverCandidates(repoRootURL: repoRootURL)
  }

  /// Applies Swift index store configuration into project config.
  package static func applySwiftConfig(
    indexStore: String,
    into projectConfig: inout ProjectConfig
  ) {
    projectConfig[SwiftLanguage.self] = SwiftLanguage.Config(indexStore: indexStore)
  }

  /// Applies TypeScript tsconfig paths configuration into project config.
  package static func applyTypeScriptConfig(
    tsconfigs: [String],
    into projectConfig: inout ProjectConfig
  ) {
    projectConfig[TypeScriptLanguage.self] = TypeScriptLanguage.Config(tsconfig: tsconfigs)
  }

  /// Detects languages with source files present in the repository root.
  package static func detectLanguages(in repoRootURL: URL) -> [SupportedLanguage] {
    SupportedLanguage.allCases.filter { $0.spec.hasSources(in: repoRootURL) }
  }
}
