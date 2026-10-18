import Foundation
import InvariantCore

enum LanguageConfigPrompt {
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
