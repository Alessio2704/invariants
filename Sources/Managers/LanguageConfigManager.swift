package import Core
package import Foundation

/// Pure domain manager for language analysis candidate discovery and configuration injection.
/// Headless: zero terminal prompting or CLI dependencies.
package enum LanguageConfigManager {
  /// Discovers candidate paths for a supported language's configuration.
  package static func discoverCandidates(for language: SupportedLanguage, repoRootURL: URL) -> [String] {
    language.spec.discoverCandidates(repoRootURL: repoRootURL)
  }

  /// Applies a language configuration dynamically into a repository languages configuration.
  package static func applyConfig(
    _ config: any LanguageConfiguration,
    for language: SupportedLanguage,
    into languagesConfig: inout LanguagesConfig
  ) {
    languagesConfig[language] = config
  }

  /// Detects languages with source files present in the repository root.
  package static func detectLanguages(in repoRootURL: URL) -> [SupportedLanguage] {
    SupportedLanguage.allCases.filter { $0.spec.hasSources(in: repoRootURL) }
  }
}
