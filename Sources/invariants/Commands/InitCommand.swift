import ArgumentParser
import Core
import Foundation
import Workflows

struct InitCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "init",
    abstract: "Initialize invariants in a project and sign registry v1."
  )

  @Option(name: .long, help: "Default branch name (default: auto-detected or main).")
  var branch: String?

  @Option(
    name: [.short, .customLong("languages"), .customLong("lang")],
    parsing: .upToNextOption,
    help: ArgumentHelp(
      "Target languages to configure (\(SupportedLanguage.allCases.map(\.rawValue).joined(separator: ", ")))."
    )
  )
  var languages: [SupportedLanguage] = []

  @Option(name: .long, help: "Custom SSH key path for signing.")
  var key: String?

  func run() async throws {
    let repoRoot = try RepoLocator.discover()
    try await RepoLocator.withRepoRoot(repoRoot) {
      do {
        try await InitWorkflow.execute(
          input: .init(branch: branch, languages: languages, keyPath: key)
        )
      } catch is InitWorkflowError {
        throw ExitCode(1)
      }
    }
  }
}
