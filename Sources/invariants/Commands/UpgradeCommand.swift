import ArgumentParser
import Core
import Foundation
import Terminal
import Workflows

struct UpgradeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "upgrade",
    abstract: "Re-verify rules and upgrade engine range in registry after an engine version update."
  )

  @OptionGroup
  var signing: SigningOptions

  func run() async throws {
    do {
      let repoRoot = try RepoLocator.discover()
      try await RepoLocator.withRepoRoot(repoRoot) {
        try await UpgradeWorkflow.execute(keyPath: signing.key)
      }
    } catch {
      Terminal.error(error.localizedDescription)
      throw ExitCode(1)
    }
  }
}
