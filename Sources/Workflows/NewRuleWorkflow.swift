package import Core
import Foundation
import Managers
import Terminal

/// Interactive CLI workflow to scaffold new draft invariant rules.
package enum NewRuleWorkflow {
  /// Scaffolds a new draft rule, creates directory templates, and displays next steps.
  package static func execute(id: String, targets: [TargetLanguage] = []) throws {
    let declaredTargets = try resolveTargets(id: id, explicitTargets: targets)

    try RuleScaffoldManager.scaffoldRule(
      id: id,
      targets: declaredTargets,
      in: RepoLocator.current
    )

    Terminal.success("Scaffolded draft rule '\(id)' at invariants/rules/\(id)/")
    Terminal.info("Next steps:")
    Terminal.info("  1. Write fixtures first in should_fail and should_pass (they are the spec).")
    Terminal.info("  2. Implement the check in rule.\(declaredTargets[0].rawValue).")
    Terminal.info("  3. Run 'invariants rule test \(id)' until green.")
    Terminal.info("  4. Run 'invariants rule add \(id)' to lock and activate with Touch ID.")
  }

  private static func resolveTargets(id: String, explicitTargets: [TargetLanguage]) throws -> [TargetLanguage] {
    if !explicitTargets.isEmpty {
      return explicitTargets
    }

    let options = TargetLanguage.allCases.map { lang in
      let exts = lang.spec.sourceExtensions.map { ".\($0)" }.joined(separator: " ")
      return TerminalPrompt.Option(value: lang, label: lang.spec.displayName, annotation: "extensions: \(exts)")
    }
    let selected = try TerminalPrompt.promptMultiSelection(
      title: "Select target language(s) for rule '\(id)':",
      options: options
    )
    guard !selected.isEmpty else {
      throw RuleScaffoldError.noTargetsSpecified
    }
    return selected
  }
}
