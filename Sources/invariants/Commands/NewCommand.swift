import ArgumentParser
import Core
import Foundation
import Terminal
import Workflows

struct NewCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "new",
    abstract: "Scaffold a new draft invariant rule."
  )

  @Argument(help: "The unique identifier of the rule (e.g. no-raw-text).")
  var id: String

  @Option(name: .long, help: "Comma-separated target languages: swift, ts.")
  var targets: String = "swift"

  func run() async throws {
    do {
      let repoRoot = try RepoLocator.discover()
      try RepoLocator.withRepoRoot(repoRoot) {
        try NewRuleWorkflow.execute(id: id, targets: targets)
      }
    } catch {
      Terminal.error(error.localizedDescription)
      throw ExitCode(1)
    }
  }
}
