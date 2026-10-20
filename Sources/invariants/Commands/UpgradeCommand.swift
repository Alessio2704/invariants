import ArgumentParser
import Core
import Foundation
import Workflows

struct UpgradeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "upgrade",
    abstract: "Re-verify rules and upgrade engine range in registry after an engine version update."
  )

  @Option(name: .long, help: "Custom SSH key path for signing.")
  var key: String?

  func run() async throws {
    do {
      let repoRoot = try RepoLocator.discover()
      try await RepoLocator.withRepoRoot(repoRoot) {
        try await UpgradeWorkflow.execute(keyPath: key)
      }
    } catch {
      fputs("Error: \(error.localizedDescription)\n", stderr)
      throw ExitCode(1)
    }
  }
}
