import ArgumentParser
import Core
import Foundation
import Terminal
import Workflows

struct TestCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "test",
    abstract: "Execute fixtures for a rule from the working tree."
  )

  @Argument(help: "The rule ID to test.")
  var id: String

  func run() async throws {
    do {
      let repoRoot = try RepoLocator.discover()
      try await RepoLocator.withRepoRoot(repoRoot) {
        let passed = try await TestRuleWorkflow.execute(ruleId: id)
        if !passed {
          throw ExitCode(1)
        }
      }
    } catch let exitCode as ExitCode {
      throw exitCode
    } catch {
      Terminal.error(error.localizedDescription)
      throw ExitCode(1)
    }
  }
}
