package import Core
import Foundation

/// Pure domain manager for language analysis candidate discovery and configuration injection.
/// Headless: zero terminal prompting or CLI dependencies.
package enum LanguageConfigManager {
  /// Discovers candidate paths for a supported language's configuration.
  package static func discoverCandidates(for language: SupportedLanguage) -> [String] {
    language.spec.discoverCandidates()
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
  package static func detectLanguages() -> [SupportedLanguage] {
    SupportedLanguage.allCases.filter { $0.spec.hasSources() }
  }
}
