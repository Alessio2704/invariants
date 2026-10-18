import ArgumentParser
import Core
import Foundation
import Workflows

struct ConfigCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "config",
    abstract: "Modify language analysis inputs in registry.languages with impact verification."
  )

  @Option(
    name: [.short, .customLong("languages"), .customLong("language"), .customLong("lang")],
    parsing: .upToNextOption,
    help: ArgumentHelp(
      "Target languages to reconfigure (\(SupportedLanguage.allCases.map(\.rawValue).joined(separator: ", ")))."
    )
  )
  var languages: [SupportedLanguage] = []

  @Option(name: .long, help: "Default protected trunk branch name (e.g. main).")
  var defaultBranch: String?

  @Option(name: .long, help: "Custom SSH key path for signing.")
  var key: String?

  func run() async throws {
    do {
      try await ConfigWorkflow.execute(
        languages: languages,
        defaultBranch: defaultBranch,
        keyPath: key
      )
    } catch {
      fputs("Error: \(error.localizedDescription)\n", stderr)
      throw ExitCode(1)
    }
  }
}
