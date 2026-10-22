import ArgumentParser
import Core
import Foundation
import Terminal
import Workflows

struct AddCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "add",
    abstract: "Lock and activate a draft rule into the signed registry."
  )

  @Argument(help: "The rule ID to add.")
  var id: String

  @OptionGroup
  var signing: SigningOptions

  func run() async throws {
    do {
      let repoRoot = try RepoLocator.discover()
      try await RepoLocator.withRepoRoot(repoRoot) {
        try await AddRuleWorkflow.execute(ruleId: id, keyPath: signing.key)
      }
    } catch {
      Terminal.error(error.localizedDescription)
      throw ExitCode(1)
    }
  }
}
