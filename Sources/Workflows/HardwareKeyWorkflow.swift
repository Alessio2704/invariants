import Core
package import Foundation
import Managers
import Terminal

/// Interactive CLI workflow orchestrating hardware key generation, rotation, inspection, and cleanup.
package enum HardwareKeyWorkflow {
  @discardableResult
  package static func generate(
    force: Bool = false
  ) async throws -> URL {
    let defaultKey = SystemEnvironment.defaultSigningKeyURL
    let defaultPub = defaultKey.appendingPathExtension("pub")

    if FileManager.default.fileExists(atPath: defaultKey.path) && !force {
      Terminal.info("Local signing key already exists at \(defaultKey.path).")
      if FileManager.default.fileExists(atPath: defaultPub.path) {
        let pub = try defaultPub.readTrimmedUTF8()
        if !pub.isEmpty {
          Terminal.line("\nPublic Key:\n  \(pub)\n")
        }
      }
      Terminal.info(
        "Use 'invariants key show' to view your public key or 'invariants key reset' to generate a fresh one.")
      return defaultKey
    }

    Terminal.info("Touch your Touch ID sensor to enroll your hardware signing key in Apple Secure Enclave...")
    let generatedKey = try await HardwareKeyManager.generateHardwareKey(at: defaultKey, force: force)

    let pubKey = try defaultPub.readTrimmedUTF8()

    Terminal.success("Created Apple Secure Enclave P-256 signing key: \(generatedKey.path)")
    Terminal.success("Protected by Touch ID biometric hardware authorization")
    Terminal.line("\nPublic Key:")
    Terminal.line("  \(pubKey)\n")
    Terminal.info("To enroll this key in an Invariants project:")
    Terminal.item("If you are a project maintainer, run:")
    Terminal.info("      invariants signers add \"\(pubKey)\"")
    Terminal.item("Otherwise, share the public key above with your repository lead.")

    return generatedKey
  }

  package static func show() throws {
    let defaultPub = SystemEnvironment.defaultSigningKeyURL.appendingPathExtension("pub")
    guard FileManager.default.fileExists(atPath: defaultPub.path) else {
      throw KeyLifecycleError.publicKeyNotFound(defaultPub.path)
    }
    let pubKey = try defaultPub.readTrimmedUTF8()
    guard !pubKey.isEmpty else {
      throw KeyLifecycleError.publicKeyNotFound(defaultPub.path)
    }
    Terminal.line(pubKey)
  }

  package static func status() async {
    let pubKey = await statusLocal()
    statusProjectIfAvailable(for: pubKey)
  }

  private static func statusLocal() async -> String? {
    let defaultKey = SystemEnvironment.defaultSigningKeyURL
    let inspection = await HardwareKeyManager.inspectKey(at: defaultKey)

    Terminal.header("[Local Machine Identity]")
    if FileManager.default.fileExists(atPath: defaultKey.path) {
      Terminal.field("Private Key:", value: defaultKey.path)
      if let pub = inspection.pubKey {
        if let type = inspection.keyType {
          Terminal.field("Key Type:", value: type)
        }
        Terminal.field("Public Key:", value: pub)
        if let fp = inspection.fingerprint {
          Terminal.field("Fingerprint:", value: fp)
        }
      }
    } else {
      Terminal.field("Private Key:", value: "Not Found (\(defaultKey.path))")
      Terminal.info("  To generate a key, run: invariants key generate")
    }

    if inspection.backupCount > 0 {
      let sshDir = defaultKey.deletingLastPathComponent()
      Terminal.field("Backups:", value: "\(inspection.backupCount) archived rotation backup(s) in \(sshDir.path)")
    }
    return inspection.pubKey
  }

  private static func statusProjectIfAvailable(for pubKey: String?) {
    Terminal.line()
    guard let repoRoot = try? RepoLocator.discover() else {
      Terminal.header("[Active Project]")
      Terminal.info("  Not inside an Invariants repository.")
      return
    }

    RepoLocator.withRepoRoot(repoRoot) {
      Terminal.header("[Active Project: \(repoRoot.lastPathComponent)]")
      let lockURL = RegistryManager.registryURL()
      let signersURL = RegistryManager.allowedSignersURL()

      let hasLock = FileManager.default.fileExists(atPath: lockURL.path)
      let hasSigners = FileManager.default.fileExists(atPath: signersURL.path)
      if hasLock && hasSigners {
        do {
          let lockData = try Data(contentsOf: lockURL)
          let reg = try CanonicalJSON.parse(data: lockData)
          Terminal.field("Registry:", value: "version \(reg.version) (\(reg.rules.count) active rule(s))")
          Terminal.field("Trunk:", value: reg.defaultBranch)
        } catch {
          Terminal.field("Registry:", value: "Error reading registry.lock: \(error.localizedDescription)")
        }

        if let pubKey {
          do {
            let signersFile = try AllowedSignersFile.read(from: signersURL)
            if let matchedEntry = signersFile.entries.first(where: { $0.matches(keyString: pubKey) }) {
              if matchedEntry.isExpired() {
                Terminal.field("Your Status:", value: "❌ Revoked / Expired in this repository")
                Terminal.field("Entry:", value: matchedEntry.serialize())
              } else {
                Terminal.field("Your Status:", value: "✅ Authorized Active Signer")
              }
            } else {
              Terminal.field("Your Status:", value: "ℹ️ Read-Only (Not enrolled in invariants/allowed_signers)")
              Terminal.info("  To authorize, have a lead run: invariants signers add \"\(pubKey)\"")
            }
          } catch {
            Terminal.field(
              "Your Status:", value: "⚠️ Error reading invariants/allowed_signers: \(error.localizedDescription)")
          }
        } else {
          Terminal.field("Your Status:", value: "ℹ️ Read-Only (No local key to check against allowed_signers)")
        }
      } else {
        Terminal.info("  Invariants:  Not initialized in this repository.")
        Terminal.info("  To initialize, run: invariants init")
      }
    }
  }

  package static func rotate() async throws {
    let defaultKey = SystemEnvironment.defaultSigningKeyURL
    guard FileManager.default.fileExists(atPath: defaultKey.path) else {
      throw KeyLifecycleError.keyNotFound(defaultKey.path)
    }

    Terminal.info("Touch your Touch ID sensor to enroll a new hardware signing key in Apple Secure Enclave...")
    let (backupKey, _) = try await HardwareKeyManager.rotateHardwareKey(at: defaultKey)
    let pubURL = defaultKey.appendingPathExtension("pub")

    Terminal.success("Local key rotated successfully.")
    Terminal.info("Old key archived to: \(backupKey.path)")
    let newPub = try pubURL.readTrimmedUTF8()
    if !newPub.isEmpty {
      Terminal.line("\nNew Public Key:\n  \(newPub)\n")
    }

    Terminal.info("Next steps:")
    Terminal.info("To update this key in your project(s), run in each relevant repository:")
    Terminal.info("    invariants signers rotate")
    Terminal.info("(or share the new public key above with your repository lead).")
  }

  package static func delete(skipConfirmation: Bool = false) async throws {
    let defaultKey = SystemEnvironment.defaultSigningKeyURL
    let defaultPub = defaultKey.appendingPathExtension("pub")

    guard
      FileManager.default.fileExists(atPath: defaultKey.path) || FileManager.default.fileExists(atPath: defaultPub.path)
    else {
      Terminal.info("No signing key found at \(defaultKey.path).")
      return
    }

    if !skipConfirmation && TerminalPrompt.isInteractive {
      let confirmed = TerminalPrompt.promptConfirmation(
        question: "Are you sure you want to delete \(defaultKey.path)?",
        default: false
      )
      guard confirmed else {
        Terminal.info("Aborted.")
        return
      }
    }

    Terminal.info("Touch your Touch ID sensor to confirm deleting your Apple Secure Enclave signing key...")
    try await HardwareKeyManager.deleteHardwareKey(at: defaultKey)

    Terminal.success("Deleted local signing key: \(defaultKey.path)")
    Terminal.line("\n⚠️  Important Reminder:")
    Terminal.info("This removed the private key from this Mac.")
    Terminal.info("If this key was registered in any Git projects, remember to have a team lead run:")
    Terminal.info("    invariants signers revoke \"<identity>\"")
    Terminal.info("in those repositories to remove its signing authorization.")
  }

  package static func reset(skipConfirmation: Bool = false) async throws {
    let defaultKey = SystemEnvironment.defaultSigningKeyURL

    if FileManager.default.fileExists(atPath: defaultKey.path) {
      if !skipConfirmation && TerminalPrompt.isInteractive {
        let confirmed = TerminalPrompt.promptConfirmation(
          question: "This will archive your current key and generate a brand-new one. Continue?",
          default: false
        )
        guard confirmed else {
          Terminal.info("Aborted.")
          return
        }
      }
    }

    try await rotate()
    Terminal.success("Generated fresh Secure Enclave signing key: \(defaultKey.path)")
  }

  package static func clean(skipConfirmation: Bool = false) throws {
    let defaultKey = SystemEnvironment.defaultSigningKeyURL
    let sshDir = defaultKey.deletingLastPathComponent()
    guard let items = try? FileManager.default.contentsOfDirectory(atPath: sshDir.path) else {
      Terminal.info("No SSH directory found at \(sshDir.path).")
      return
    }

    let backups = items.filter { $0.hasPrefix(SystemPaths.keyBackupPrefix) }
    guard !backups.isEmpty else {
      Terminal.info("No rotation backup keys found in \(sshDir.path).")
      return
    }

    if !skipConfirmation && TerminalPrompt.isInteractive {
      let confirmed = TerminalPrompt.promptConfirmation(
        question: "Found \(backups.count) backup file(s) in \(sshDir.path). Delete them?",
        default: false
      )
      guard confirmed else {
        Terminal.info("Aborted.")
        return
      }
    }

    let count = try HardwareKeyManager.cleanBackups(in: sshDir)
    Terminal.success("Cleaned up \(count) rotation backup file(s) from \(sshDir.path).")
  }
}
