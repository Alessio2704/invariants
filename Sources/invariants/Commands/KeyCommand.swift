import ArgumentParser
import Foundation
import Terminal
import Workflows

struct KeyCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "key",
    abstract: "Manage your local hardware signing key in Apple Secure Enclave.",
    subcommands: [
      Generate.self,
      Show.self,
      Status.self,
      Rotate.self,
      Delete.self,
      Reset.self,
      Clean.self,
    ],
    defaultSubcommand: Status.self
  )

  struct Generate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "generate",
      abstract: "Generate a dedicated Touch ID signing key in Apple Secure Enclave."
    )

    @Flag(name: .long, help: "Overwrite existing key if one already exists.")
    var force: Bool = false

    func run() async throws {
      do {
        _ = try await HardwareKeyWorkflow.generate(force: force)
      } catch {
        Terminal.error(error.localizedDescription)
        throw ExitCode(1)
      }
    }
  }

  struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "show",
      abstract: "Print your local public signing key string to share with team leads."
    )

    func run() throws {
      do {
        try HardwareKeyWorkflow.show()
      } catch {
        Terminal.error(error.localizedDescription)
        throw ExitCode(1)
      }
    }
  }

  struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "status",
      abstract: "Display the status of your local signing key and repository authorization."
    )

    func run() async {
      await HardwareKeyWorkflow.status()
    }
  }

  struct Rotate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "rotate",
      abstract: "Rotate your local hardware signing key in Apple Secure Enclave."
    )

    func run() async throws {
      do {
        try await HardwareKeyWorkflow.rotate()
      } catch {
        Terminal.error(error.localizedDescription)
        throw ExitCode(1)
      }
    }
  }

  struct Delete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "delete",
      abstract: "Delete your local private signing key from this machine."
    )

    @Flag(name: [.customShort("y"), .long], help: "Skip confirmation prompt.")
    var yes: Bool = false

    func run() async throws {
      do {
        try await HardwareKeyWorkflow.delete(skipConfirmation: yes)
      } catch {
        Terminal.error(error.localizedDescription)
        throw ExitCode(1)
      }
    }
  }

  struct Reset: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "reset",
      abstract: "Archive current signing key and generate a fresh Secure Enclave key."
    )

    @Flag(name: [.customShort("y"), .long], help: "Skip confirmation prompt.")
    var yes: Bool = false

    func run() async throws {
      do {
        try await HardwareKeyWorkflow.reset(skipConfirmation: yes)
      } catch {
        Terminal.error(error.localizedDescription)
        throw ExitCode(1)
      }
    }
  }

  struct Clean: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "clean",
      abstract: "Remove archived rotation backup keys (.bak-*) from ~/.ssh/."
    )

    @Flag(name: [.customShort("y"), .long], help: "Skip confirmation prompt.")
    var yes: Bool = false

    func run() throws {
      do {
        try HardwareKeyWorkflow.clean(skipConfirmation: yes)
      } catch {
        Terminal.error(error.localizedDescription)
        throw ExitCode(1)
      }
    }
  }
}
