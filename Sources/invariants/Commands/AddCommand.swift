import ArgumentParser
import Core
import Foundation
import Workflows

struct AddCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "add",
    abstract: "Lock and activate a draft rule into the signed registry."
  )

  @Argument(help: "The rule ID to add.")
  var id: String

  @Option(name: .long, help: "Custom SSH key path for signing.")
  var key: String?

  func run() async throws {
    do {
      try await AddRuleWorkflow.execute(ruleId: id, keyPath: key)
    } catch {
      fputs("Error: \(error.localizedDescription)\n", stderr)
      throw ExitCode(1)
    }
  }
}
