import ArgumentParser
import Core
import Foundation
import Terminal
import Workflows

struct SignersCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "signers",
    abstract: "Manage trusted SSH public keys in repository invariants/allowed_signers.",
    subcommands: [
      List.self,
      Add.self,
      Revoke.self,
      Rotate.self,
    ],
    defaultSubcommand: List.self
  )

  struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "list",
      abstract: "List all trusted signers in invariants/allowed_signers."
    )

    func run() async throws {
      do {
        let repoRoot = try RepoLocator.discover()
        try RepoLocator.withRepoRoot(repoRoot) {
          try SignersWorkflow.list()
        }
      } catch {
        Terminal.error(error.localizedDescription)
        throw ExitCode(1)
      }
    }
  }

  struct Add: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "add",
      abstract: "Add an SSH public key to repository invariants/allowed_signers."
    )

    @Argument(help: "Path to public key file, raw public key string, or '[identity] <publicKey>'.")
    var arguments: [String] = []

    @Option(name: .long, help: "Identity / principal for the key (e.g. alice@plans.app).")
    var identity: String?

    @OptionGroup
    var signing: SigningOptions

    func run() async throws {
      guard !arguments.isEmpty else {
        Terminal.error("Error: Missing public key argument. Usage: invariants signers add [identity] <publicKey>")
        throw ExitCode(1)
      }

      let resolvedKey: String
      let resolvedIdentity: String?
      if arguments.count >= 2 {
        resolvedIdentity = arguments[0]
        resolvedKey = arguments[1]
      } else {
        resolvedKey = arguments[0]
        resolvedIdentity = identity
      }

      do {
        let repoRoot = try RepoLocator.discover()
        try await RepoLocator.withRepoRoot(repoRoot) {
          try await SignersWorkflow.add(key: resolvedKey, identity: resolvedIdentity, signingKey: signing.key)
        }
      } catch {
        Terminal.error(error.localizedDescription)
        throw ExitCode(1)
      }
    }
  }

  struct Revoke: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "revoke",
      abstract: "Revoke or discontinue a signer in repository invariants/allowed_signers."
    )

    @Argument(help: "Pattern to match (identity, email, or public key substring).")
    var pattern: String

    @Flag(name: .long, help: "Hard revocation: completely delete the key instead of setting valid-before.")
    var hard: Bool = false

    @OptionGroup
    var signing: SigningOptions

    func run() async throws {
      do {
        let repoRoot = try RepoLocator.discover()
        try await RepoLocator.withRepoRoot(repoRoot) {
          try await SignersWorkflow.revoke(pattern: pattern, hard: hard, signingKey: signing.key)
        }
      } catch {
        Terminal.error(error.localizedDescription)
        throw ExitCode(1)
      }
    }
  }

  struct Rotate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "rotate",
      abstract: "Rotate an authorized signer key in repository invariants/allowed_signers."
    )

    @Option(
      name: .long,
      help: "Pattern, identity, or key data of the old key being rotated. If omitted, detects most recent backup key."
    )
    var old: String?

    @Option(
      name: .long,
      help:
        "New public key string or path to new public key file. If omitted, uses local public key (~/.ssh/invariants_p256.pub)."
    )
    var new: String?

    @Option(
      name: .long,
      help: "Sunset duration in seconds before the old key is fully revoked (default: 86400 / 24h)."
    )
    var sunset: TimeInterval = 86400

    @OptionGroup
    var signing: SigningOptions

    func run() async throws {
      do {
        let repoRoot = try RepoLocator.discover()
        try await RepoLocator.withRepoRoot(repoRoot) {
          try await SignersWorkflow.rotate(old: old, new: new, sunset: sunset, signingKey: signing.key)
        }
      } catch {
        Terminal.error(error.localizedDescription)
        throw ExitCode(1)
      }
    }
  }
}
