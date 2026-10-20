import ArgumentParser
import Core
import Foundation
import Terminal
import Workflows

struct DevCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "dev",
    abstract: "Scaffold an autocompletion development workspace in invariants/.dev/."
  )

  func run() async throws {
    do {
      let repoRoot = try RepoLocator.discover()
      try RepoLocator.withRepoRoot(repoRoot) {
        try DevWorkflow.execute()
      }
    } catch {
      Terminal.error(error.localizedDescription)
      throw ExitCode(1)
    }
  }
}
