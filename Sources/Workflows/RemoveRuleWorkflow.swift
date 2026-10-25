import Core
import Foundation
import Terminal

/// Interactive CLI workflow to deactivate an invariant rule and remove it from the signed registry.
package enum RemoveRuleWorkflow {
  package static func execute(ruleId: String, deleteFromDisk: Bool, keyPath: String?) async throws {
    let repoRootURL = RepoLocator.current
    let fm = FileManager.default

    // 1. Authorize signing session upfront (fail-fast)
    let session = try SigningSession.authorize(customPath: keyPath)

    // 2. Load registry
    var registry = try await RegistryManager.loadAndVerify()

    guard registry.rules[ruleId] != nil else {
      throw RemoveRuleWorkflowError.notInRegistry(ruleId)
    }

    let ruleDir = repoRootURL.appendingPathComponent("invariants/rules/\(ruleId)")

    // 3. Confirm before modifying any files or bumping version
    let targetVersion = registry.version + 1
    let confirm = try TerminalPrompt.promptConfirmation(
      question: "Deactivate and remove invariant '\(ruleId)' from registry v\(targetVersion)?",
      default: true
    )
    guard confirm else {
      Terminal.info("Aborted.")
      return
    }

    registry.rules.removeValue(forKey: ruleId)
    registry.version = targetVersion

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

    // 4. Sign updated registry
    Terminal.info("Signing registry v\(registry.version) with key \(session.privateKeyURL.lastPathComponent)...")
    try await RegistryManager.saveAndSign(
      registry: registry,
      keyURL: session.privateKeyURL
    )

    // 5. Commit
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

  package var errorDescription: String? {
    switch self {
    case .notInRegistry(let id):
      return "Rule '\(id)' is not in registry."
    }
  }
}
