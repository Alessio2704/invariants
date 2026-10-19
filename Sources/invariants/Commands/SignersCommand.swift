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
        let signersURL = RegistryManager.allowedSignersURL()

        guard FileManager.default.fileExists(atPath: signersURL.path) else {
          print("No invariants/allowed_signers file found at \(signersURL.path).")
          return
        }

        let signersFile = try AllowedSignersFile.read(from: signersURL)
        if signersFile.entries.isEmpty {
          print("invariants/allowed_signers at \(signersURL.path) is empty.")
          return
        }

        print("Trusted Invariant Signers (\(signersURL.path)):")
        print("──────────────────────────────────────────────────")
        for (index, entry) in signersFile.entries.enumerated() {
          let status = entry.isActive() ? "Active" : "Discontinued / Expired"
          print("[\(index + 1)] [\(status)] \(entry.serialize())")
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
        let signersURL = RegistryManager.allowedSignersURL()

        let keyContent: String
        let expanded = (key as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) {
          keyContent = try URL(fileURLWithPath: expanded).readTrimmedUTF8()
        } else {
          keyContent = key.trimmed
        }

        guard keyContent.hasPrefix("ssh-") || keyContent.hasPrefix("ecdsa-") || keyContent.hasPrefix("sk-") else {
          fputs("Error: Invalid SSH public key format. Must start with 'ssh-', 'ecdsa-', or 'sk-'.\n", stderr)
          throw ExitCode(1)
        }

        let principal = identity ?? "*"
        var signersFile = try AllowedSignersFile.read(from: signersURL)
        try signersFile.addPublicKey(keyContent, principal: principal, namespaces: ["invariants"])
        try signersFile.write(to: signersURL)

        // Bump registry version & sign
        try await SignersCommand.bumpAndSignRegistry(customSigningKey: signingKey)
        print("✓ Added signer to \(signersURL.path) and signed updated registry.")
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
        let signersURL = RegistryManager.allowedSignersURL()

        guard FileManager.default.fileExists(atPath: signersURL.path) else {
          fputs("Error: invariants/allowed_signers not found at \(signersURL.path).\n", stderr)
          throw ExitCode(1)
        }

        var signersFile = try AllowedSignersFile.read(from: signersURL)
        let matchedCount: Int

        if hard {
          let initialCount = signersFile.entries.count
          signersFile.entries.removeAll {
            $0.matches(keyString: pattern) || $0.principals.contains(pattern) || $0.comment?.contains(pattern) == true
          }
          matchedCount = initialCount - signersFile.entries.count
        } else {
          matchedCount = signersFile.revoke(keyDataOrSubstring: pattern, effectiveDate: Date())
        }

        guard matchedCount > 0 else {
          print("No signers matched pattern '\(pattern)'.")
          return
        }

        try signersFile.write(to: signersURL)

        // Bump registry version & sign
        try await SignersCommand.bumpAndSignRegistry(customSigningKey: signingKey)
        let mode = hard ? "Hard revoked (purged)" : "Soft revoked (valid-before set)"
        print("✓ \(mode) \(matchedCount) signer(s) matching '\(pattern)' and signed updated registry.")
      }
    }
  }

  struct Rotate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "rotate",
      abstract: "Rotate the local Invariants signing key and update repository invariants/allowed_signers."
    )

    func run() async throws {
      let repoRoot = try RepoLocator.discover()
      try await RepoLocator.withRepoRoot(repoRoot) {
        try await HardwareKeyWorkflow.rotateInRepo()
      }
    }
  }

  private static func bumpAndSignRegistry(customSigningKey: String?) async throws {
    let lockURL = RegistryManager.registryURL()

    guard FileManager.default.fileExists(atPath: lockURL.path) else {
      fputs("Error: registry.lock not found in \(RepoLocator.current.path).\n", stderr)
      throw ExitCode(1)
    }

    let data = try Data(contentsOf: lockURL)
    var registry = try CanonicalJSON.parse(data: data)

    registry.version += 1
    guard let keyURL = await SigningKeyWorkflow.resolveOrPrompt(customPath: customSigningKey) else {
      fputs("Error: No Invariants signing key resolved to sign registry update.\n", stderr)
      throw ExitCode(1)
    }

    try await RegistryManager.saveAndSign(registry: registry, keyURL: keyURL)
  }
}
