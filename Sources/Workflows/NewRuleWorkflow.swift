import Core
import Foundation
import Managers
import Terminal

/// Interactive CLI workflow to scaffold new draft invariant rules.
package enum NewRuleWorkflow {
  /// Scaffolds a new draft rule, creates directory templates, and displays next steps.
  package static func execute(id: String, targets: String) throws {
    let targetList = targets.split(separator: ",").map(\.trimmed)
    var declaredTargets: [TargetLanguage] = []
    for t in targetList {
      guard let lang = TargetLanguage(rawValue: t) else {
        throw RuleScaffoldError.invalidTarget(t)
      }
      declaredTargets.append(lang)
    }

    guard !declaredTargets.isEmpty else {
      throw RuleScaffoldError.noTargetsSpecified
    }

    try RuleScaffoldManager.scaffoldRule(
      id: id,
      targets: declaredTargets,
      in: RepoLocator.current
    )

    Terminal.success("Scaffolded draft rule '\(id)' at invariants/rules/\(id)/")
    Terminal.info("Next steps:")
    Terminal.info("  1. Write fixtures first in should_fail and should_pass (they are the spec).")
    Terminal.info("  2. Implement the check in rule.\(declaredTargets[0].rawValue).")
    Terminal.info("  3. Run 'invariants test \(id)' until green.")
    Terminal.info("  4. Run 'invariants add \(id)' to lock and activate with Touch ID.")
  }
}
