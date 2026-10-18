import ArgumentParser
import Core
import Foundation
import Workflows

struct UpdateCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "update",
    abstract: "Update an active invariant rule with weakening detection and signature locking."
  )

  @Argument(help: "The rule ID to update.")
  var id: String

  @Option(name: .long, help: "Custom SSH key path for signing.")
  var key: String?

  @Option(name: .long, help: "Confirm update by providing the exact rule ID when weakening is detected.")
  var confirmId: String?

  @Flag(name: .long, help: "Confirm update even if red-flag weakening is detected.")
  var confirm: Bool = false

  func run() async throws {
    let repoRoot = try RepoLocator.discover()
    try await RepoLocator.withRepoRoot(repoRoot) {
      do {
        try await UpdateRuleWorkflow.execute(
          input: .init(
            id: id,
            keyPath: key,
            confirmId: confirmId,
            confirm: confirm
          )
        )
      } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        throw ExitCode(1)
      }
    }
  }
}
