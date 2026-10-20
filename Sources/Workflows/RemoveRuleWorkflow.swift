import Core
import Foundation
import Terminal

/// Interactive CLI workflow to deactivate an invariant rule and remove it from the signed registry.
package enum RemoveRuleWorkflow {
  package static func execute(ruleId: String, deleteFromDisk: Bool, keyPath: String?) async throws {
    let repoRootURL = RepoLocator.current
    let fm = FileManager.default

    // 1. Load registry
    var registry = try await RegistryManager.loadAndVerify(
      installedEngineVersion: EngineVersion.current
    )

    guard registry.rules[ruleId] != nil else {
      throw RemoveRuleWorkflowError.notInRegistry(ruleId)
    }

    let ruleDir = repoRootURL.appendingPathComponent("invariants/rules/\(ruleId)")

    // 2. Remove rule
    registry.rules.removeValue(forKey: ruleId)
    registry.version += 1

    var pathsToCommit = [
      "invariants/registry.lock",
      "invariants/registry.lock.sig",
    ]

    if deleteFromDisk {
      if fm.fileExists(atPath: ruleDir.path) {
        try fm.removeItem(at: ruleDir)
        pathsToCommit.append("invariants/rules/\(ruleId)")
      }
    }

    if TerminalPrompt.isInteractive {
      let confirm = TerminalPrompt.promptConfirmation(
        question: "Deactivate and remove invariant '\(ruleId)' from registry v\(registry.version + 1)?",
        default: true
      )
      guard confirm else {
        Terminal.info("Aborted.")
        return
      }
    }

    // 3. Resolve key and sign
    guard let keyURL = await SigningKeyWorkflow.resolveOrPrompt(customPath: keyPath) else {
      throw RemoveRuleWorkflowError.noSigningKey
    }

    Terminal.info("Signing registry v\(registry.version)...")
    try await RegistryManager.saveAndSign(
      registry: registry,
      keyURL: keyURL
    )

    // 4. Commit
    try await GitClient.commit(
      paths: pathsToCommit,
      message: "Remove invariant '\(ruleId)' (registry v\(registry.version))"
    )

    Terminal.success("Rule '\(ruleId)' removed from registry v\(registry.version).")
    if !deleteFromDisk {
      Terminal.info("Notice: Directory kept as draft at invariants/rules/\(ruleId)/.")
    }
  }
}

package enum RemoveRuleWorkflowError: LocalizedError, Sendable {
  case notInRegistry(String)
  case noSigningKey

  package var errorDescription: String? {
    switch self {
    case .notInRegistry(let id):
      return "Rule '\(id)' is not in registry."
    case .noSigningKey:
      return "No signing key found. Run 'invariants key generate' or specify --key <path>."
    }
  }
}
