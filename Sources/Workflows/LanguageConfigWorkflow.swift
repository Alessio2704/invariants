package import Core
import Foundation
import Managers
import Terminal

/// Interactive CLI workflow for configuring project language analysis inputs.
package enum LanguageConfigWorkflow {
  /// Resolves language configurations for project initialization, querying the user interactively if needed.
  package static func resolveConfigurations(
    explicitLanguages: [SupportedLanguage],
    baseConfig: LanguagesConfig = LanguagesConfig()
  ) throws -> LanguagesConfig {
    guard explicitLanguages.isEmpty else {
      return try configure(languages: explicitLanguages, baseConfig: baseConfig)
    }

    let targetLanguages = try resolveDiscoveredOrInteractiveLanguages()
    return try configure(languages: targetLanguages, baseConfig: baseConfig)
  }

  private static func resolveDiscoveredOrInteractiveLanguages() throws -> [SupportedLanguage] {
    let detected = LanguageConfigManager.detectLanguages()

    guard !detected.isEmpty else {
      Terminal.line("")
      Terminal.warning("No known source files detected in repository.")
      return try promptForLanguageSelection()
    }

    Terminal.line("")
    Terminal.header("Discovered languages in this repository:")
    for lang in detected {
      let exts = lang.spec.sourceExtensions.map { ".\($0)" }.joined(separator: ", ")
      Terminal.item("\(lang.spec.displayName) (\(exts))")
    }

    let confirmed = try TerminalPrompt.promptConfirmation(
      question: "Configure invariants for discovered languages?",
      default: true
    )
    guard confirmed else {
      return try promptForLanguageSelection()
    }

    return detected
  }

  /// Interactively configures a collection of languages and returns the updated project configuration.
  package static func configure(
    languages: [SupportedLanguage],
    baseConfig: LanguagesConfig = LanguagesConfig()
  ) throws -> LanguagesConfig {
    var languagesConfig = baseConfig
    for lang in languages {
      try configureLanguage(lang, into: &languagesConfig)
    }
    return languagesConfig
  }

  /// Prompts the user to select from available languages.
  package static func promptForLanguageSelection(title: String = "Available languages:") throws -> [SupportedLanguage] {
    let options = SupportedLanguage.allCases.map { lang in
      let exts = lang.spec.sourceExtensions.map { ".\($0)" }.joined(separator: ", ")
      return TerminalPrompt.Option(value: lang, label: lang.spec.displayName, annotation: "extensions: \(exts)")
    }
    return try TerminalPrompt.promptMultiSelection(title: title, options: options)
  }

  private static func configureLanguage(
    _ language: SupportedLanguage,
    into languagesConfig: inout LanguagesConfig
  ) throws {
    if let config = try promptForConfig(for: language) {
      LanguageConfigManager.applyConfig(config, for: language, into: &languagesConfig)
    }
  }

  private static func promptForConfig(
    for language: SupportedLanguage
  ) throws -> (any LanguageConfiguration)? {
    let spec = language.spec
    let inputs = LanguageConfigManager.discoverAnalysisInputs(for: language)
    let descriptor = spec.configPromptDescriptor

    if inputs.isEmpty {
      Terminal.line("")
      Terminal.warning(descriptor.noInputsFoundMessage)
      let choice = try TerminalPrompt.prompt(question: descriptor.manualPromptQuestion)
      guard !choice.isEmpty else { return nil }
      return spec.makeConfig(from: [choice])
    }

    switch descriptor.selectionStyle {
    case .single(let selectionTitle):
      if inputs.count == 1, let first = inputs.first {
        return spec.makeConfig(from: [first])
      }
      let options = inputs.map { TerminalPrompt.Option(value: $0, label: $0) }
      if let choice = try TerminalPrompt.promptSelection(
        title: selectionTitle,
        options: options,
        default: 0,
        customHandler: { $0 }
      ) {
        return spec.makeConfig(from: [choice])
      }
      return nil

    case .multiple(let confirmationQuestion):
      let joined = inputs.joined(separator: ", ")
      let confirm = try TerminalPrompt.promptConfirmation(
        question: "\(confirmationQuestion) (\(joined))?",
        default: true
      )
      if confirm {
        return spec.makeConfig(from: inputs)
      } else {
        let custom = try TerminalPrompt.prompt(question: descriptor.manualFallbackQuestion)
        guard !custom.isEmpty else { return nil }
        return spec.makeConfig(from: [custom])
      }
    }
  }
}
