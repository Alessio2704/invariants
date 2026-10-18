import Foundation
import InvariantCore

/// CLI-aware orchestrator responsible for discovering and harvesting language analysis configurations.
enum LanguageConfigManager {
  /// Resolves language configurations for project initialization, querying the user interactively if needed.
  static func resolveConfigurations(
    explicitLanguages: [SupportedLanguage],
    repoRootURL: URL,
    into projectConfig: inout ProjectConfig
  ) {
    let targetLanguages: [SupportedLanguage]

    if !explicitLanguages.isEmpty {
      targetLanguages = explicitLanguages
    } else {
      let detected = SupportedLanguage.allCases.filter { $0.spec.hasSources(in: repoRootURL) }
      if !detected.isEmpty {
        if TerminalPrompt.isInteractive {
          print("\nDiscovered languages in this repository:")
          for lang in detected {
            let exts = lang.spec.sourceExtensions.map { ".\($0)" }.joined(separator: ", ")
            print("  • \(lang.spec.displayName) (\(exts))")
          }
          let confirmed = TerminalPrompt.promptConfirmation(
            question: "Configure invariants for discovered languages?",
            default: true
          )
          if confirmed {
            targetLanguages = detected
          } else {
            targetLanguages = promptForLanguageSelection()
          }
        } else {
          targetLanguages = detected
        }
      } else {
        if TerminalPrompt.isInteractive {
          print("\nNo known source files detected in repository.")
          targetLanguages = promptForLanguageSelection()
        } else {
          targetLanguages = []
        }
      }
    }

    for lang in targetLanguages {
      configureLanguage(lang, repoRootURL: repoRootURL, into: &projectConfig)
    }
  }

  /// Prompts the user to select from available languages.
  static func promptForLanguageSelection(title: String = "Available languages:") -> [SupportedLanguage] {
    let options = SupportedLanguage.allCases.map { lang in
      let exts = lang.spec.sourceExtensions.map { ".\($0)" }.joined(separator: ", ")
      return TerminalPrompt.Option(value: lang, label: lang.spec.displayName, annotation: "extensions: \(exts)")
    }
    return TerminalPrompt.promptMultiSelection(title: title, options: options)
  }

  /// Interactively configures a single language and stores it in the project configuration.
  static func configureLanguage(
    _ language: SupportedLanguage,
    repoRootURL: URL,
    into projectConfig: inout ProjectConfig
  ) {
    switch language {
    case .swift:
      if let cfg = promptForSwiftConfig(repoRootURL: repoRootURL) {
        projectConfig[SwiftLanguage.self] = cfg
      }
    case .ts:
      if let cfg = promptForTypeScriptConfig(repoRootURL: repoRootURL) {
        projectConfig[TypeScriptLanguage.self] = cfg
      }
    }
  }

  private static func promptForSwiftConfig(repoRootURL: URL) -> SwiftLanguage.Config? {
    let candidates = SwiftLanguage.discoverCandidates(repoRootURL: repoRootURL)
    if candidates.isEmpty {
      guard TerminalPrompt.isInteractive else { return nil }
      print(
        "\nSwift sources detected, but no index store candidate was found "
          + "(e.g. build/Index.noindex/DataStore, .build/out, or .build/debug/index/store)."
      )
      let choice = TerminalPrompt.prompt(question: "Enter index store path (press Enter to skip / configure later)")
      return choice.isEmpty ? nil : SwiftLanguage.Config(indexStore: choice)
    } else {
      let options = candidates.map { TerminalPrompt.Option(value: $0, label: $0) }
      if let choice = TerminalPrompt.promptSelection(
        title: "Discovered Swift Index candidates:",
        options: options,
        default: 0,
        customHandler: { $0 }
      ) {
        return SwiftLanguage.Config(indexStore: choice)
      }
      return nil
    }
  }

  private static func promptForTypeScriptConfig(repoRootURL: URL) -> TypeScriptLanguage.Config? {
    let candidates = TypeScriptLanguage.discoverCandidates(repoRootURL: repoRootURL)
    if candidates.isEmpty {
      guard TerminalPrompt.isInteractive else { return nil }
      print("\nTypeScript sources detected, but no tsconfig.json candidate was found.")
      let custom = TerminalPrompt.prompt(
        question: "Enter tsconfig relative path (press Enter to skip / configure later)")
      return custom.isEmpty ? nil : TypeScriptLanguage.Config(tsconfig: [custom])
    } else {
      let joined = candidates.joined(separator: ", ")
      let confirm = TerminalPrompt.promptConfirmation(
        question: "Use discovered tsconfig paths (\(joined))?",
        default: true
      )
      if confirm {
        return TypeScriptLanguage.Config(tsconfig: candidates)
      } else {
        let custom = TerminalPrompt.prompt(question: "Enter tsconfig relative path (press Enter to skip)")
        return custom.isEmpty ? nil : TypeScriptLanguage.Config(tsconfig: [custom])
      }
    }
  }
}
