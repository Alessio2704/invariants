import ArgumentParser
import Core
import Foundation
import Terminal
import Workflows

struct CheckCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "check",
    abstract: "Execute the complete invariant enforcement pipeline."
  )

  @Flag(name: .long, help: "Emit output in machine-readable JSON format.")
  var json: Bool = false

  @Flag(
    name: .long,
    help:
      "Enforce Git pre-push protection (rejects force-push or deletion of default branch) by reading ref lines from stdin."
  )
  var prePush: Bool = false

  func run() async throws {
    do {
      let repoRoot = try RepoLocator.discover()
      try await RepoLocator.withRepoRoot(repoRoot) {
        let passed = try await CheckWorkflow.execute(json: json, prePush: prePush)
        if !passed {
          throw ExitCode(1)
        }
      }
    } catch CheckWorkflowError.securityViolation {
      throw ExitCode(70)
    } catch let exitCode as ExitCode {
      throw exitCode
    } catch {
      Terminal.error(error.localizedDescription)
      throw ExitCode(1)
    }
  }
}
