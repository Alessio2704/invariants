import ArgumentParser
import Core
import Foundation
import Terminal
import Workflows

struct UpdateCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "update",
    abstract: "Update an active invariant rule with weakening detection and signature locking."
  )

  @Argument(help: "The rule ID to update.")
  var id: String

  @OptionGroup
  var signing: SigningOptions

  @Option(name: .long, help: "Confirm update by providing the exact rule ID when weakening is detected.")
  var confirmId: String?

  @Flag(name: .long, help: "Confirm update even if red-flag weakening is detected.")
  var confirm: Bool = false

  func run() async throws {
    do {
      let repoRoot = try RepoLocator.discover()
      try await RepoLocator.withRepoRoot(repoRoot) {
        try await UpdateRuleWorkflow.execute(
          input: .init(
            id: id,
            keyPath: signing.key,
            confirmId: confirmId,
            confirm: confirm
          )
        )
      }
    } catch {
      Terminal.error(error.localizedDescription)
      throw ExitCode(1)
    }
  }
}
