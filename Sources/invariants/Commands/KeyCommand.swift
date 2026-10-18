import ArgumentParser
import Core
import Foundation
import Workflows

struct KeyCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "key",
    abstract: "Manage your local hardware signing key and check repository enrollment.",
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
      abstract: "Generate a dedicated Touch ID signing key in the Apple Secure Enclave."
    )

    @Flag(name: .long, help: "Overwrite existing key if one already exists.")
    var force: Bool = false

    func run() async throws {
      let keyURL = try await HardwareKeyWorkflow.generate(force: force)
      let pubURL = keyURL.appendingPathExtension("pub")
      let pubContent = try? String(contentsOf: pubURL, encoding: .utf8)
      if let pubKey = pubContent?.trimmingCharacters(in: .whitespacesAndNewlines) {
        if let root = try? RepoLocator.discover() {
          RepoLocator.withRepoRoot(root) {
            HardwareKeyWorkflow.printProjectEnrollment(pubKey: pubKey)
          }
        } else {
          print("Share your public key above with your repository lead to be added as an authorized signer.")
        }
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
        fputs("Error: \(error.localizedDescription)\nRun 'invariants key generate' to create one.\n", stderr)
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
      let pubKey = await HardwareKeyWorkflow.statusLocal()
      if let root = try? RepoLocator.discover() {
        RepoLocator.withRepoRoot(root) {
          HardwareKeyWorkflow.statusProject(for: pubKey)
        }
      } else {
        HardwareKeyWorkflow.statusProjectOutsideRepo()
      }
    }
  }

  struct Rotate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "rotate",
      abstract: "Rotate local signing key and update the active repository's allowed_signers."
    )

    func run() async throws {
      if let root = try? RepoLocator.discover() {
        let signersURL = RepoLocator.withRepoRoot(root) {
          RegistryManager.allowedSignersURL()
        }
        if FileManager.default.fileExists(atPath: signersURL.path) {
          try await RepoLocator.withRepoRoot(root) {
            try await SignersCommand.Rotate().run()
          }
          return
        }
      }

      do {
        try await HardwareKeyWorkflow.rotate()
        print(
          "Notice: Not inside an Invariants repository. To enroll this key, have a lead run 'invariants signers add'."
        )
      } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
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
        fputs("Error: \(error.localizedDescription)\n", stderr)
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
        fputs("Error: \(error.localizedDescription)\n", stderr)
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
        fputs("Error: \(error.localizedDescription)\n", stderr)
        throw ExitCode(1)
      }
    }
  }
}
