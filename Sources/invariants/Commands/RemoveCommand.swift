import ArgumentParser
import Core
import Foundation
import Terminal
import Workflows

struct RemoveCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "remove",
    abstract: "Deactivate an invariant rule and remove it from the signed registry."
  )

  @Argument(help: "The rule ID to remove.")
  var id: String

  @Flag(name: .long, help: "Delete the rule directory from disk instead of keeping it as a draft.")
  var delete: Bool = false

  @Option(name: .long, help: "Custom SSH key path for signing.")
  var key: String?

  func run() async throws {
    do {
      let repoRoot = try RepoLocator.discover()
      try await RepoLocator.withRepoRoot(repoRoot) {
        try await RemoveRuleWorkflow.execute(ruleId: id, deleteFromDisk: delete, keyPath: key)
      }
    } catch {
      Terminal.error(error.localizedDescription)
      throw ExitCode(1)
    }
  }
}
