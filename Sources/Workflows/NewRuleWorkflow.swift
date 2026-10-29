package import Core
import Foundation
import Managers
import Terminal

/// Interactive CLI workflow to scaffold new draft invariant rules.
package enum NewRuleWorkflow {
  /// Scaffolds a new draft rule, creates directory templates, and displays next steps.
  package static func execute(id: String, targets: [TargetLanguage] = []) throws {
    let registry = try loadRegistry()
    let configured = registry.languages
    guard !configured.isEmpty else {
      throw RuleScaffoldError.noConfiguredLanguages
    }
    let declaredTargets = try resolveTargets(id: id, explicitTargets: targets, configured: configured)

    var targetUnits: [TargetLanguage: [String]] = [:]
    for target in declaredTargets {
      let availableUnits = registry.ast.units(for: target)
      if availableUnits.count <= 1 {
        targetUnits[target] = availableUnits.isEmpty ? ["main"] : availableUnits
      } else {
        if Terminal.isInteractive {
          let options = availableUnits.map { TerminalPrompt.Option(value: $0, label: $0) }
          let selected = try TerminalPrompt.promptMultiSelection(
            title: "Select AST unit(s) for '\(target.rawValue)' targeted by rule '\(id)':",
            options: options
          )
          targetUnits[target] = selected.isEmpty ? availableUnits : selected
        } else {
          targetUnits[target] = availableUnits
        }
      }
    }

    try RuleScaffoldManager.scaffoldRule(
      id: id,
      targets: declaredTargets,
      targetUnits: targetUnits,
      in: RepoLocator.current
    )

    Terminal.success("Scaffolded draft rule '\(id)' at invariants/rules/\(id)/")
    Terminal.info("Next steps:")
    Terminal.info("  1. Write fixtures first in should_fail and should_pass (they are the spec).")
    Terminal.info("  2. Implement the check in rule.\(declaredTargets[0].rawValue).")
    Terminal.info("  3. Run 'invariants rule test \(id)' until green.")
    Terminal.info("  4. Run 'invariants rule add \(id)' to lock and activate with Touch ID.")
  }

  private static func loadRegistry() throws -> Registry {
    let lockURL = RegistryManager.registryURL()
    guard FileManager.default.fileExists(atPath: lockURL.path) else {
      throw RuleScaffoldError.notInitialized
    }
    guard let data = try? Data(contentsOf: lockURL),
      let registry = try? CanonicalJSON.parse(data: data)
    else {
      throw RuleScaffoldError.notInitialized
    }
    return registry
  }

  private static func resolveTargets(
    id: String,
    explicitTargets: [TargetLanguage],
    configured: [TargetLanguage]
  ) throws -> [TargetLanguage] {
    if !explicitTargets.isEmpty {
      for target in explicitTargets {
        guard configured.contains(target) else {
          throw RuleScaffoldError.targetNotConfigured(target, configured: configured)
        }
      }
      return explicitTargets
    }

    let options = configured.map { lang in
      let exts = lang.spec.sourceExtensions.map { ".\($0)" }.joined(separator: " ")
      return TerminalPrompt.Option(value: lang, label: lang.spec.displayName, annotation: "extensions: \(exts)")
    }
    let preselected: Set<Int> = configured.count == 1 ? [0] : []
    let selected = try TerminalPrompt.promptMultiSelection(
      title: "Select target language(s) for rule '\(id)':",
      options: options,
      preselectedIndices: preselected
    )
    guard !selected.isEmpty else {
      throw RuleScaffoldError.noTargetsSpecified
    }
    return selected
  }
}
