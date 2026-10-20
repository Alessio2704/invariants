import ArgumentParser
import Core
import Foundation
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
      let repoRoot = try RepoLocator.discover()
      try RepoLocator.withRepoRoot(repoRoot) {
        do {
          try SignersWorkflow.list()
        } catch {
          fputs("Error: \(error.localizedDescription)\n", stderr)
          throw ExitCode(1)
        }
      }
    }
  }

  struct Add: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "add",
      abstract: "Add an SSH public key to repository invariants/allowed_signers."
    )

    @Argument(help: "Path to public key file (e.g. ~/.ssh/invariants_p256.pub) or raw public key string.")
    var key: String

    @Option(name: .long, help: "Identity / principal for the key (e.g. alice@plans.app).")
    var identity: String?

    @Option(name: .long, help: "Path to your private signing key to authorize this addition.")
    var signingKey: String?

    func run() async throws {
      let repoRoot = try RepoLocator.discover()
      try await RepoLocator.withRepoRoot(repoRoot) {
        do {
          try await SignersWorkflow.add(key: key, identity: identity, signingKey: signingKey)
        } catch {
          fputs("Error: \(error.localizedDescription)\n", stderr)
          throw ExitCode(1)
        }
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

    @Option(name: .long, help: "Path to your private signing key to authorize this revocation.")
    var signingKey: String?

    func run() async throws {
      let repoRoot = try RepoLocator.discover()
      try await RepoLocator.withRepoRoot(repoRoot) {
        do {
          try await SignersWorkflow.revoke(pattern: pattern, hard: hard, signingKey: signingKey)
        } catch {
          fputs("Error: \(error.localizedDescription)\n", stderr)
          throw ExitCode(1)
        }
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

    @Option(name: .long, help: "Path to your private signing key to authorize this rotation.")
    var signingKey: String?

    func run() async throws {
      let repoRoot = try RepoLocator.discover()
      try await RepoLocator.withRepoRoot(repoRoot) {
        do {
          try await SignersWorkflow.rotate(old: old, new: new, sunset: sunset, signingKey: signingKey)
        } catch {
          fputs("Error: \(error.localizedDescription)\n", stderr)
          throw ExitCode(1)
        }
      }
    }
  }
}
