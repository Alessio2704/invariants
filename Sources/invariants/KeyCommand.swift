import ArgumentParser
import Foundation
import InvariantCore

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
      _ = try await KeyCommand.generateHardwareKey(force: force, showContextualStatus: true)
    }
  }

  struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "show",
      abstract: "Print your local public signing key string to share with team leads."
    )

    func run() async throws {
      let defaultPub = SystemEnvironment.defaultSigningKeyURL.appendingPathExtension("pub")
      guard FileManager.default.fileExists(atPath: defaultPub.path),
        let pubKey = try? String(contentsOf: defaultPub, encoding: .utf8).trimmingCharacters(
          in: .whitespacesAndNewlines),
        !pubKey.isEmpty
      else {
        fputs(
          "Error: No public key found at \(defaultPub.path).\nRun 'invariants key generate' to create one.\n", stderr)
        throw ExitCode(1)
      }
      print(pubKey)
    }
  }

  struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "status",
      abstract: "Display the status of your local signing key and repository authorization."
    )

    func run() async throws {
      let defaultKey = SystemEnvironment.defaultSigningKeyURL
      let defaultPub = defaultKey.appendingPathExtension("pub")

      print("[Local Machine Identity]")
      if FileManager.default.fileExists(atPath: defaultKey.path) {
        print("  Private Key: \(defaultKey.path)")
        let pubKey = try? String(contentsOf: defaultPub, encoding: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if let pubKey, !pubKey.isEmpty {
          let type: String
          if pubKey.contains("ecdsa-sha2-nistp256") {
            type = "Apple Secure Enclave (Touch ID NIST P-256)"
          } else {
            type = "Software Key"
          }
          print("  Key Type:    \(type)")
          print("  Public Key:  \(pubKey)")
          if let fp = await SigningClient.fingerprint(pubKeyURL: defaultPub) {
            print("  Fingerprint: \(fp)")
          }
        }
      } else {
        print("  Private Key: Not Found (\(defaultKey.path))")
        print("  To generate a key, run: invariants key generate")
      }

      // Check rotation backups
      let sshDir = defaultKey.deletingLastPathComponent()
      if let items = try? FileManager.default.contentsOfDirectory(atPath: sshDir.path) {
        let backups = items.filter {
          $0.hasPrefix(SystemPaths.keyBackupPrefix) && !$0.hasSuffix(".pub")
        }
        if !backups.isEmpty {
          print("  Backups:     \(backups.count) archived rotation backup(s) in \(sshDir.path)")
        }
      }

      print("")
      if let repoRoot = CLIHelpers.findRepoRoot() {
        print("[Active Project: \(repoRoot.lastPathComponent)]")
        let lockURL = RegistryManager.registryURL(repoRoot: repoRoot)
        let signersURL = RegistryManager.allowedSignersURL(repoRoot: repoRoot)

        let hasLock = FileManager.default.fileExists(atPath: lockURL.path)
        let hasSigners = FileManager.default.fileExists(atPath: signersURL.path)
        if hasLock && hasSigners {
          if let lockData = try? Data(contentsOf: lockURL), let reg = try? CanonicalJSON.parse(data: lockData) {
            print("  Registry:    version \(reg.version) (\(reg.rules.count) active rule(s))")
            print("  Trunk:       \(reg.defaultBranch)")
          }

          let signersFile = (try? AllowedSignersFile.read(from: signersURL)) ?? AllowedSignersFile()
          let pubKey = try? String(contentsOf: defaultPub, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
          if let pubKey, !pubKey.isEmpty {
            if let matchedEntry = signersFile.entries.first(where: { $0.matches(keyString: pubKey) }) {
              if matchedEntry.isExpired() {
                print("  Your Status: ❌ Revoked / Expired in this repository")
                print("  Entry:       \(matchedEntry.serialize())")
              } else {
                print("  Your Status: ✅ Authorized Active Signer")
              }
            } else {
              print("  Your Status: ℹ️ Read-Only (Not enrolled in invariants/allowed_signers)")
              print("  To authorize, have a lead run: invariants signers add \"\(pubKey)\"")
            }
          } else {
            print("  Your Status: ℹ️ Read-Only (No local key to check against allowed_signers)")
          }
        } else {
          print("  Invariants:  Not initialized in this repository.")
          print("  To initialize, run: invariants init")
        }
      } else {
        print("[Active Project]")
        print("  Not inside a Git repository.")
      }
    }
  }

  struct Rotate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "rotate",
      abstract: "Rotate local signing key and update the active repository's allowed_signers."
    )

    func run() async throws {
      let defaultKey = SystemEnvironment.defaultSigningKeyURL
      guard FileManager.default.fileExists(atPath: defaultKey.path) else {
        fputs("Error: No existing signing key found at \(defaultKey.path) to rotate.\n", stderr)
        throw ExitCode(1)
      }

      // If inside an Invariants repository with allowed_signers, delegate to SignersCommand.Rotate
      if let repoRoot = CLIHelpers.findRepoRoot() {
        let signersURL = RegistryManager.allowedSignersURL(repoRoot: repoRoot)
        if FileManager.default.fileExists(atPath: signersURL.path) {
          try await SignersCommand.Rotate().run()
          return
        }
      }

      // Standalone machine rotation (outside any Invariants repository)
      let formatter = DateFormatter()
      formatter.dateFormat = "yyyyMMddHHmmss"
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      let ts = formatter.string(from: Date())

      let baseName = defaultKey.lastPathComponent
      let backupKey = defaultKey.deletingLastPathComponent().appendingPathComponent("\(baseName).bak-\(ts)")
      let backupPub = backupKey.appendingPathExtension("pub")
      let oldPubURL = defaultKey.appendingPathExtension("pub")

      try FileManager.default.moveItem(at: defaultKey, to: backupKey)
      if FileManager.default.fileExists(atPath: oldPubURL.path) {
        try FileManager.default.moveItem(at: oldPubURL, to: backupPub)
      }

      print("Touch your Touch ID sensor to enroll a new hardware signing key in Apple Secure Enclave...")
      try await SigningClient.generateSigningKey(at: defaultKey)

      print("✓ Local key rotated successfully.")
      print("Old key archived to: \(backupKey.path)")
      let newPub = (try? String(contentsOf: oldPubURL, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if let newPub, !newPub.isEmpty {
        print("\nNew Public Key:\n  \(newPub)\n")
      }
      print(
        "Notice: Not inside an Invariants repository. To enroll this key, have a lead run 'invariants signers add'."
      )
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
      let defaultKey = SystemEnvironment.defaultSigningKeyURL
      let defaultPub = defaultKey.appendingPathExtension("pub")

      guard
        FileManager.default.fileExists(atPath: defaultKey.path)
          || FileManager.default.fileExists(atPath: defaultPub.path)
      else {
        print("No signing key found at \(defaultKey.path).")
        return
      }

      if !yes && CLIHelpers.isInteractive {
        let confirmed = CLIHelpers.prompt(
          question: "Are you sure you want to delete \(defaultKey.path)? [y/N]", default: "n")
        guard confirmed.lowercased() == "y" || confirmed.lowercased() == "yes" else {
          print("Aborted.")
          return
        }
      }

      print("Touch your Touch ID sensor to confirm deleting your Apple Secure Enclave signing key...")
      do {
        try await SigningClient.deleteSigningKey(at: defaultKey)
      } catch {
        fputs("Error: Could not delete signing key: \(error)\n", stderr)
        throw ExitCode(1)
      }

      print("✓ Deleted local signing key: \(defaultKey.path)")
      print("\n⚠️  Important Reminder:")
      print("This removed the private key from this Mac.")
      print("If this key was registered in any Git projects, remember to have a team lead run:")
      print("    invariants signers revoke \"<identity>\"")
      print("in those repositories to remove its signing authorization.")
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
      let defaultKey = SystemEnvironment.defaultSigningKeyURL
      let defaultPub = defaultKey.appendingPathExtension("pub")

      if FileManager.default.fileExists(atPath: defaultKey.path) {
        if !yes && CLIHelpers.isInteractive {
          let confirmed = CLIHelpers.prompt(
            question: "This will archive your current key and generate a brand-new one. Continue? [y/N]",
            default: "n"
          )
          guard confirmed.lowercased() == "y" || confirmed.lowercased() == "yes" else {
            print("Aborted.")
            return
          }
        }

        // Archive old key
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let ts = formatter.string(from: Date())
        let baseName = defaultKey.lastPathComponent
        let backupKey = defaultKey.deletingLastPathComponent().appendingPathComponent("\(baseName).bak-\(ts)")
        let backupPub = backupKey.appendingPathExtension("pub")

        try? FileManager.default.moveItem(at: defaultKey, to: backupKey)
        if FileManager.default.fileExists(atPath: defaultPub.path) {
          try? FileManager.default.moveItem(at: defaultPub, to: backupPub)
        }
        print("Archived old key to \(backupKey.path).")
      }

      print("Touch your Touch ID sensor to enroll a fresh hardware signing key in Apple Secure Enclave...")
      try await SigningClient.generateSigningKey(at: defaultKey)

      guard
        let pubKey = try? String(contentsOf: defaultPub, encoding: .utf8).trimmingCharacters(
          in: .whitespacesAndNewlines)
      else {
        fputs("Error: Could not read new public key at \(defaultPub.path).\n", stderr)
        throw ExitCode(1)
      }

      print("✓ Generated fresh Secure Enclave signing key: \(defaultKey.path)")
      print("\nNew Public Key:")
      print("  \(pubKey)\n")
      print(
        "Remember to share this new public key with your repository leads to be enrolled via 'invariants signers add'.")
    }
  }

  struct Clean: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "clean",
      abstract: "Remove archived rotation backup keys (.bak-*) from ~/.ssh/."
    )

    @Flag(name: [.customShort("y"), .long], help: "Skip confirmation prompt.")
    var yes: Bool = false

    func run() async throws {
      let defaultKey = SystemEnvironment.defaultSigningKeyURL
      let sshDir = defaultKey.deletingLastPathComponent()

      guard let items = try? FileManager.default.contentsOfDirectory(atPath: sshDir.path) else {
        print("No SSH directory found at \(sshDir.path).")
        return
      }

      let backups = items.filter { $0.hasPrefix(SystemPaths.keyBackupPrefix) }
      guard !backups.isEmpty else {
        print("No rotation backup keys found in \(sshDir.path).")
        return
      }

      if !yes && CLIHelpers.isInteractive {
        let confirmed = CLIHelpers.prompt(
          question: "Found \(backups.count) backup file(s) in \(sshDir.path). Delete them? [y/N]",
          default: "n"
        )
        guard confirmed.lowercased() == "y" || confirmed.lowercased() == "yes" else {
          print("Aborted.")
          return
        }
      }

      var deletedCount = 0
      for item in backups {
        let itemURL = sshDir.appendingPathComponent(item)
        if (try? FileManager.default.removeItem(at: itemURL)) != nil {
          deletedCount += 1
        }
      }

      print("✓ Cleaned up \(deletedCount) rotation backup file(s) from \(sshDir.path).")
    }
  }
}

extension KeyCommand {
  @discardableResult
  static func generateHardwareKey(
    force: Bool = false,
    showContextualStatus: Bool = true
  ) async throws -> URL {
    let defaultKey = SystemEnvironment.defaultSigningKeyURL
    let defaultPub = defaultKey.appendingPathExtension("pub")

    if FileManager.default.fileExists(atPath: defaultKey.path) && !force {
      print("Local signing key already exists at \(defaultKey.path).")
      let pub = try? String(contentsOf: defaultPub, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if let pub, !pub.isEmpty {
        print("\nPublic Key:\n  \(pub)")
      }
      print("\nUse 'invariants key show' to view your public key or 'invariants key reset' to generate a fresh one.")
      return defaultKey
    }

    print("Touch your Touch ID sensor to enroll your hardware signing key in Apple Secure Enclave...")
    do {
      try await SigningClient.generateSigningKey(at: defaultKey)
    } catch {
      fputs("Error: Could not generate Secure Enclave key: \(error)\n", stderr)
      throw ExitCode(1)
    }

    guard
      let pubKey = try? String(contentsOf: defaultPub, encoding: .utf8).trimmingCharacters(
        in: .whitespacesAndNewlines)
    else {
      fputs("Error: Key was generated but could not read public key at \(defaultPub.path).\n", stderr)
      throw ExitCode(1)
    }

    print("✓ Created Apple Secure Enclave P-256 signing key: \(defaultKey.path)")
    print("✓ Protected by Touch ID biometric hardware authorization")
    print("\nPublic Key:")
    print("  \(pubKey)\n")

    if showContextualStatus {
      printContextualStatus(pubKey: pubKey)
    }

    return defaultKey
  }

  private static func printContextualStatus(pubKey: String) {
    if let repoRoot = CLIHelpers.findRepoRoot() {
      let signersURL = RegistryManager.allowedSignersURL(repoRoot: repoRoot)
      if FileManager.default.fileExists(atPath: signersURL.path) {
        let signersFile = (try? AllowedSignersFile.read(from: signersURL)) ?? AllowedSignersFile()
        if signersFile.entries.contains(where: { $0.matches(keyString: pubKey) && $0.isActive() }) {
          print("✓ This key is already authorized in '\(repoRoot.lastPathComponent)'.")
        } else {
          print("ℹ️  This key is not yet enrolled in '\(repoRoot.lastPathComponent)'.")
          print("Share your public key above with a repository lead to be added via:")
          print("    invariants signers add \"\(pubKey)\"")
        }
      } else {
        print(
          "ℹ️  Invariants is not initialized in '\(repoRoot.lastPathComponent)'. Run 'invariants init' to seal it.")
      }
    } else {
      print("Share your public key above with your repository lead to be added as an authorized signer.")
    }
  }
}
