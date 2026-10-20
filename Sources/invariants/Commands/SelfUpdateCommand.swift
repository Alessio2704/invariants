import ArgumentParser
import Core
import Foundation
import Terminal
import Workflows

struct SelfUpdateCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "self-update",
    abstract: "Download, verify, compile, and install an engine release tag."
  )

  @Argument(help: "Signed Git tag to update to (e.g. v1.0.1).")
  var tag: String

  @Option(name: .long, help: "Pre-built stage directory path for offline installation.")
  var stagePath: String?

  func run() async throws {
    do {
      try await SelfUpdateWorkflow.execute(tag: tag, stagePath: stagePath)
    } catch let exitCode as ExitCode {
      throw exitCode
    } catch {
      Terminal.error(error.localizedDescription)
      throw ExitCode(1)
    }
  }
}
