import ArgumentParser
import Core
import Foundation
import Workflows

struct UninstallCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "uninstall",
    abstract: "Completely uninstall invariants engine and remove system symlinks."
  )

  @Flag(name: [.short, .long], help: "Bypass confirmation prompt.")
  var yes: Bool = false

  func run() async throws {
    do {
      try await UninstallWorkflow.execute(yes: yes)
    } catch {
      fputs("Error: Uninstall failed: \(error.localizedDescription)\n", stderr)
      throw ExitCode(1)
    }
  }
}
