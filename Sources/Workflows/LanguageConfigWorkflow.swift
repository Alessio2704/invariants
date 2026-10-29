package import Core
import Foundation
import Terminal

/// Interactive CLI workflow for configuring project language analysis inputs.
package enum LanguageConfigWorkflow {
  /// Resolves language configurations for project initialization, querying the user interactively if needed.
  package static func resolveConfigurations(
    explicitLanguages: [SupportedLanguage],
    baseLanguages: [SupportedLanguage] = [],
    baseAST: ASTConfig = ASTConfig()
  ) throws -> (languages: [SupportedLanguage], ast: ASTConfig) {
    guard explicitLanguages.isEmpty else {
      return try configure(
        languages: explicitLanguages,
        baseLanguages: baseLanguages,
        baseAST: baseAST
      )
    }

    let targetLanguages = try resolveDiscoveredOrInteractiveLanguages()
    return try configure(
      languages: targetLanguages,
      baseLanguages: baseLanguages,
      baseAST: baseAST
    )
  }

  private static func resolveDiscoveredOrInteractiveLanguages() throws -> [SupportedLanguage] {
    let detected = SupportedLanguage.detectLanguages()

    guard !detected.isEmpty else {
      Terminal.line("")
      Terminal.warning("No known source files detected in repository.")
      return try promptForLanguageSelection()
    }

    if !Terminal.isInteractive {
      return detected
    }

    Terminal.line("")
    Terminal.header("Discovered languages in this repository:")
    for lang in detected {
      let exts = lang.spec.sourceExtensions.map { ".\($0)" }.joined(separator: " ")
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
    baseLanguages: [SupportedLanguage] = [],
    baseAST: ASTConfig = ASTConfig()
  ) throws -> (languages: [SupportedLanguage], ast: ASTConfig) {
    var astConfig = baseAST
    for lang in languages {
      try configureLanguage(lang, into: &astConfig)
    }
    let allLangs = Array(Set(baseLanguages + languages)).sorted(by: { $0.rawValue < $1.rawValue })
    return (languages: allLangs, ast: astConfig)
  }

  /// Prompts the user to select from available languages.
  package static func promptForLanguageSelection(title: String = "Available languages:") throws -> [SupportedLanguage] {
    let options = SupportedLanguage.allCases.map { lang in
      let exts = lang.spec.sourceExtensions.map { ".\($0)" }.joined(separator: " ")
      return TerminalPrompt.Option(value: lang, label: lang.spec.displayName, annotation: "extensions: \(exts)")
    }
    return try TerminalPrompt.promptMultiSelection(title: title, options: options)
  }

  private static func configureLanguage(
    _ language: SupportedLanguage,
    into astConfig: inout ASTConfig
  ) throws {
    let spec = language.spec
    let inputs = spec.discoverAnalysisInputs()
    let descriptor = spec.configPromptDescriptor

    var existingNames = Set(astConfig.units(for: language))
    var selectedPaths: [String] = []

    if inputs.isEmpty {
      if Terminal.isInteractive {
        Terminal.line("")
        Terminal.warning(descriptor.noInputsFoundMessage)
        let choice = try TerminalPrompt.prompt(question: descriptor.manualPromptQuestion)
        if !choice.isEmpty {
          selectedPaths.append(choice)
        }
      }
    } else {
      if !Terminal.isInteractive {
        selectedPaths = inputs
      } else {
        switch descriptor.selectionStyle {
        case .single(let selectionTitle):
          if inputs.count == 1, let first = inputs.first {
            selectedPaths = [first]
          } else {
            let options = inputs.map { TerminalPrompt.Option(value: $0, label: $0) }
            if let choice = try TerminalPrompt.promptSelection(
              title: selectionTitle,
              options: options,
              default: 0,
              customHandler: { $0 }
            ) {
              selectedPaths = [choice]
            }
          }
        case .multiple(let confirmationQuestion):
          let joined = inputs.joined(separator: ", ")
          let confirm = try TerminalPrompt.promptConfirmation(
            question: "\(confirmationQuestion) (\(joined))?",
            default: true
          )
          if confirm {
            selectedPaths = inputs
          } else {
            let custom = try TerminalPrompt.prompt(question: descriptor.manualFallbackQuestion)
            if !custom.isEmpty {
              selectedPaths = [custom]
            }
          }
        }
      }
    }

    var units = astConfig[language]
    for path in selectedPaths {
      guard let unitConfig = spec.makeUnitConfig(from: path) else { continue }
      let unitName = spec.inferDefaultUnitName(for: path, existingNames: existingNames)
      existingNames.insert(unitName)
      units[unitName] = unitConfig
    }
    astConfig[language] = units
  }
}
