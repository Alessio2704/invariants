import ArgumentParser
import Core
import Foundation
import Terminal
import Workflows

struct ConfigCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "config",
    abstract: "Modify language analysis inputs in registry.languages with impact verification."
  )

  @Option(
    name: [
      .short, .customLong("targets"), .customLong("target"), .customLong("languages"), .customLong("language"),
      .customLong("lang"),
    ],
    parsing: .upToNextOption,
    help: ArgumentHelp(
      "Target languages to reconfigure (\(SupportedLanguage.allCases.map(\.rawValue).joined(separator: " ")))."
    )
  )
  var languages: [SupportedLanguage] = []

  @Option(name: .long, help: "Default protected trunk branch name (e.g. main).")
  var defaultBranch: String?

  @OptionGroup
  var signing: SigningOptions

  func run() async throws {
    do {
      let repoRoot = try RepoLocator.discover()
      try await RepoLocator.withRepoRoot(repoRoot) {
        try await ConfigWorkflow.execute(
          languages: languages,
          defaultBranch: defaultBranch,
          keyPath: signing.key
        )
      }
    } catch {
      Terminal.error(error.localizedDescription)
      throw ExitCode(1)
    }
  }
}
