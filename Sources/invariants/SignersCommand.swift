import ArgumentParser
import Foundation
import InvariantCore

struct SignersCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "signers",
    abstract: "Manage trusted SSH public keys in allowed_signers.",
    subcommands: [
      List.self,
      Add.self,
      Remove.self,
    ],
    defaultSubcommand: List.self
  )

  struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "list",
      abstract: "List all trusted signers in allowed_signers."
    )

    func run() async throws {
      let env = SystemEnvironment.standard
      let signersURL = env.allowedSignersURL

      guard FileManager.default.fileExists(atPath: signersURL.path) else {
        print("No allowed_signers file found at \(signersURL.path).")
        return
      }

      let content = try String(contentsOf: signersURL, encoding: .utf8)
      let lines = content.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }

      if lines.isEmpty {
        print("allowed_signers at \(signersURL.path) is empty.")
        return
      }

      print("Trusted Signers (\(signersURL.path)):")
      print("──────────────────────────────────────────────────")
      for (index, line) in lines.enumerated() {
        print("[\(index + 1)] \(line)")
      }
    }
  }

  struct Add: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "add",
      abstract: "Add an SSH public key to allowed_signers."
    )

    @Argument(help: "Path to public key file (e.g. ~/.ssh/id_ed25519.pub) or raw public key string.")
    var key: String

    @Option(name: .long, help: "Identity / principal for the key.")
    var identity: String = "owner"

    @Option(name: .long, help: "Comma-separated namespaces for which the key is valid.")
    var namespaces: String = "git,invariants"

    func run() async throws {
      let env = SystemEnvironment.standard
      let sudoClient = SudoClient()

      let keyContent: String
      let expanded = (key as NSString).expandingTildeInPath
      if FileManager.default.fileExists(atPath: expanded) {
        let raw = try String(contentsOfFile: expanded, encoding: .utf8)
        keyContent = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      } else {
        keyContent = key.trimmingCharacters(in: .whitespacesAndNewlines)
      }

      guard keyContent.hasPrefix("ssh-") || keyContent.hasPrefix("ecdsa-") else {
        fputs("Error: Invalid SSH public key format. Must start with 'ssh-' or 'ecdsa-'.\n", stderr)
        throw ExitCode(1)
      }

      let entry = "\(identity) namespaces=\"\(namespaces)\" \(keyContent)\n"
      do {
        try await sudoClient.writePrivilegedFile(at: env.allowedSignersURL, content: entry, append: true)
        print("✓ Successfully added signer to \(env.allowedSignersURL.path)")
      } catch {
        fputs("Error: Failed to write allowed_signers: \(error)\n", stderr)
        throw ExitCode(1)
      }
    }
  }

  struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "remove",
      abstract: "Remove a signer matching a pattern from allowed_signers."
    )

    @Argument(help: "Pattern to match (identity, comment, or public key substring).")
    var pattern: String

    func run() async throws {
      let env = SystemEnvironment.standard
      let sudoClient = SudoClient()
      let signersURL = env.allowedSignersURL

      guard FileManager.default.fileExists(atPath: signersURL.path) else {
        fputs("Error: allowed_signers file not found at \(signersURL.path).\n", stderr)
        throw ExitCode(1)
      }

      let content = try String(contentsOf: signersURL, encoding: .utf8)
      let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

      var keptLines: [String] = []
      var removedCount = 0

      for line in lines {
        if !line.trimmingCharacters(in: .whitespaces).isEmpty && line.contains(pattern) {
          removedCount += 1
        } else {
          keptLines.append(line)
        }
      }

      guard removedCount > 0 else {
        print("No signers matched pattern '\(pattern)'.")
        return
      }

      let updatedContent = keptLines.joined(separator: "\n")
      do {
        try await sudoClient.writePrivilegedFile(at: signersURL, content: updatedContent, append: false)
        print("✓ Successfully removed \(removedCount) signer(s) matching '\(pattern)'.")
      } catch {
        fputs("Error: Failed to update allowed_signers: \(error)\n", stderr)
        throw ExitCode(1)
      }
    }
  }
}
