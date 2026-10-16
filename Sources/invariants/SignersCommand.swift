import ArgumentParser
import Foundation
import InvariantCore

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
      let repoRoot = CLIHelpers.findRepoRoot() ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      let signersURL = RegistryManager.allowedSignersURL(repoRoot: repoRoot)

      guard FileManager.default.fileExists(atPath: signersURL.path) else {
        print("No invariants/allowed_signers file found at \(signersURL.path).")
        return
      }

      let content = try String(contentsOf: signersURL, encoding: .utf8)
      let lines =
        content.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }

      if lines.isEmpty {
        print("invariants/allowed_signers at \(signersURL.path) is empty.")
        return
      }

      print("Trusted Invariant Signers (\(signersURL.path)):")
      print("──────────────────────────────────────────────────")
      for (index, line) in lines.enumerated() {
        var status = "Active"
        if line.contains("valid-before=") {
          status = "Discontinued / Expired"
        }
        print("[\(index + 1)] [\(status)] \(line)")
      }
    }
  }

  struct Add: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "add",
      abstract: "Add an SSH public key to repository invariants/allowed_signers."
    )

    @Argument(help: "Path to public key file (e.g. ~/.ssh/id_ed25519.pub) or raw public key string.")
    var key: String

    @Option(name: .long, help: "Identity / principal for the key (e.g. alice@plans.app).")
    var identity: String?

    @Option(name: .long, help: "Path to your private signing key to authorize this addition.")
    var signingKey: String?

    func run() async throws {
      let repoRoot = CLIHelpers.findRepoRoot() ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      let signersURL = RegistryManager.allowedSignersURL(repoRoot: repoRoot)

      let keyContent: String
      let expanded = (key as NSString).expandingTildeInPath
      if FileManager.default.fileExists(atPath: expanded) {
        let raw = try String(contentsOfFile: expanded, encoding: .utf8)
        keyContent = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      } else {
        keyContent = key.trimmingCharacters(in: .whitespacesAndNewlines)
      }

      guard keyContent.hasPrefix("ssh-") || keyContent.hasPrefix("ecdsa-") || keyContent.hasPrefix("sk-") else {
        fputs("Error: Invalid SSH public key format. Must start with 'ssh-', 'ecdsa-', or 'sk-'.\n", stderr)
        throw ExitCode(1)
      }

      let principal = identity ?? "*"
      let entry = "\(principal),* namespaces=\"invariants\" \(keyContent)\n"

      var existingContent = ""
      if FileManager.default.fileExists(atPath: signersURL.path) {
        existingContent = try String(contentsOf: signersURL, encoding: .utf8)
      }
      let updatedContent =
        existingContent.hasSuffix("\n") || existingContent.isEmpty
        ? existingContent + entry : existingContent + "\n" + entry
      try updatedContent.write(to: signersURL, atomically: true, encoding: .utf8)

      // Bump registry version & sign
      try await SignersCommand.bumpAndSignRegistry(repoRoot: repoRoot, customSigningKey: signingKey)
      print("✓ Added signer to \(signersURL.path) and signed updated registry.")
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
      let repoRoot = CLIHelpers.findRepoRoot() ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      let signersURL = RegistryManager.allowedSignersURL(repoRoot: repoRoot)

      guard FileManager.default.fileExists(atPath: signersURL.path) else {
        fputs("Error: invariants/allowed_signers not found at \(signersURL.path).\n", stderr)
        throw ExitCode(1)
      }

      let content = try String(contentsOf: signersURL, encoding: .utf8)
      let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

      let formatter = DateFormatter()
      formatter.dateFormat = "yyyyMMddHHmmss"
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      let timestamp = formatter.string(from: Date())

      var updatedLines: [String] = []
      var matchedCount = 0

      for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty && !trimmed.hasPrefix("#") && line.contains(pattern) {
          matchedCount += 1
          if hard {
            // Hard revocation: omit the line entirely
            continue
          } else {
            // Soft revocation: append valid-before option
            if line.contains("namespaces=\"invariants\"") {
              let replaced = line.replacingOccurrences(
                of: "namespaces=\"invariants\"",
                with: "namespaces=\"invariants\",valid-before=\"\(timestamp)\""
              )
              updatedLines.append(replaced)
            } else {
              updatedLines.append(line)
            }
          }
        } else {
          updatedLines.append(line)
        }
      }

      guard matchedCount > 0 else {
        print("No signers matched pattern '\(pattern)'.")
        return
      }

      let updatedContent = updatedLines.joined(separator: "\n") + "\n"
      try updatedContent.write(to: signersURL, atomically: true, encoding: .utf8)

      // Bump registry version & sign
      try await SignersCommand.bumpAndSignRegistry(repoRoot: repoRoot, customSigningKey: signingKey)
      let mode = hard ? "Hard revoked (purged)" : "Soft revoked (valid-before=\(timestamp))"
      print("✓ \(mode) \(matchedCount) signer(s) matching '\(pattern)' and signed updated registry.")
    }
  }

  struct Rotate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "rotate",
      abstract: "Rotate the local Invariants signing key and update repository invariants/allowed_signers."
    )

    func run() async throws {
      let repoRoot = CLIHelpers.findRepoRoot() ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      let signersURL = RegistryManager.allowedSignersURL(repoRoot: repoRoot)
      let defaultKey = SystemEnvironment.defaultSigningKeyURL

      guard FileManager.default.fileExists(atPath: defaultKey.path) else {
        fputs("Error: No existing signing key found at \(defaultKey.path) to rotate.\n", stderr)
        throw ExitCode(1)
      }

      let oldPubURL = defaultKey.appendingPathExtension("pub")
      guard
        let oldPubContent = try? String(contentsOf: oldPubURL, encoding: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines)
      else {
        fputs("Error: Could not read existing public key at \(oldPubURL.path).\n", stderr)
        throw ExitCode(1)
      }

      // 1. Archive current key to backup
      let formatter = DateFormatter()
      formatter.dateFormat = "yyyyMMddHHmmss"
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      let ts = formatter.string(from: Date())

      let backupKey = defaultKey.deletingLastPathComponent().appendingPathComponent("invariants_ed25519.bak-\(ts)")
      let backupPub = backupKey.appendingPathExtension("pub")

      try FileManager.default.moveItem(at: defaultKey, to: backupKey)
      if FileManager.default.fileExists(atPath: oldPubURL.path) {
        try FileManager.default.moveItem(at: oldPubURL, to: backupPub)
      }

      // 2. Generate new key at defaultKey
      let sshClient = SSHKeygenClient()
      try await sshClient.generateSigningKey(at: defaultKey)

      guard
        let newPubContent = try? String(contentsOf: oldPubURL, encoding: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines)
      else {
        fputs("Error: Failed to read new public key at \(oldPubURL.path).\n", stderr)
        throw ExitCode(1)
      }

      // 3. Update in-repo allowed_signers: mark old valid-before, add new valid-after
      var content = ""
      if FileManager.default.fileExists(atPath: signersURL.path) {
        content = try String(contentsOf: signersURL, encoding: .utf8)
      }

      let validBeforeTs = formatter.string(from: Date().addingTimeInterval(86400))

      var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
      var replacedOld = false
      for i in 0..<lines.count where lines[i].contains(oldPubContent) {
        lines[i] = lines[i].replacingOccurrences(
          of: "namespaces=\"invariants\"",
          with: "namespaces=\"invariants\",valid-before=\"\(validBeforeTs)\""
        )
        replacedOld = true
      }
      if !replacedOld {
        lines.append("*,* namespaces=\"invariants\",valid-before=\"\(validBeforeTs)\" \(oldPubContent)")
      }

      let newEntry = "*,* namespaces=\"invariants\",valid-after=\"\(ts)\" \(newPubContent)"
      lines.append(newEntry)

      let updatedContent = lines.joined(separator: "\n") + "\n"
      try updatedContent.write(to: signersURL, atomically: true, encoding: .utf8)

      // 4. Bump registry & sign with old key to seal the authority transition
      try await SignersCommand.bumpAndSignRegistry(repoRoot: repoRoot, customSigningKey: backupKey.path)
      print("✓ Key rotated successfully. Old key archived to \(backupKey.path).")
    }
  }

  private static func bumpAndSignRegistry(repoRoot: URL, customSigningKey: String?) async throws {
    let registryManager = RegistryManager()
    let lockURL = RegistryManager.registryURL(repoRoot: repoRoot)

    guard FileManager.default.fileExists(atPath: lockURL.path),
      let data = try? Data(contentsOf: lockURL),
      var registry = try? CanonicalJSON.parse(data: data)
    else {
      fputs("Error: registry.lock not found in \(repoRoot.path).\n", stderr)
      throw ExitCode(1)
    }

    registry.version += 1
    guard let keyURL = CLIHelpers.promptForSigningKey(customPath: customSigningKey, repoRoot: repoRoot) else {
      fputs("Error: No Invariants signing key resolved to sign registry update.\n", stderr)
      throw ExitCode(1)
    }

    try await registryManager.saveAndSign(registry: registry, repoRoot: repoRoot, keyURL: keyURL)
  }
}
