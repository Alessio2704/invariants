import ArgumentParser
import Core
import Foundation
import Terminal
import Workflows

struct StatusCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "Report invariants configuration, signatures, floor, and rule statuses."
  )

  func run() async throws {
    do {
      let repoRoot = try RepoLocator.discover()
      await RepoLocator.withRepoRoot(repoRoot) {
        await StatusWorkflow.execute()
      }
    } catch {
      Terminal.error(error.localizedDescription)
      throw ExitCode(1)
    }
  }
}
