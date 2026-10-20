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
      print("Local signing key already exists at \(defaultKey.path).")
      if FileManager.default.fileExists(atPath: defaultPub.path) {
        let pub = try defaultPub.readTrimmedUTF8()
        if !pub.isEmpty {
          print("\nPublic Key:\n  \(pub)\n")
        }
      }
      print("Use 'invariants key show' to view your public key or 'invariants key reset' to generate a fresh one.")
      return defaultKey
    }

    print("Touch your Touch ID sensor to enroll your hardware signing key in Apple Secure Enclave...")
    let generatedKey = try await HardwareKeyManager.generateHardwareKey(at: defaultKey, force: force)

    let pubKey = try defaultPub.readTrimmedUTF8()

    print("✓ Created Apple Secure Enclave P-256 signing key: \(generatedKey.path)")
    print("✓ Protected by Touch ID biometric hardware authorization")
    print("\nPublic Key:")
    print("  \(pubKey)\n")
    print("To enroll this key in an Invariants project:")
    print("  • If you are a project maintainer, run:")
    print("      invariants signers add \"\(pubKey)\"")
    print("  • Otherwise, share the public key above with your repository lead.")

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
    print(pubKey)
  }

  package static func status() async {
    let pubKey = await statusLocal()
    statusProjectIfAvailable(for: pubKey)
  }

  private static func statusLocal() async -> String? {
    let defaultKey = SystemEnvironment.defaultSigningKeyURL
    let inspection = await HardwareKeyManager.inspectKey(at: defaultKey)

    print("[Local Machine Identity]")
    if FileManager.default.fileExists(atPath: defaultKey.path) {
      print("  Private Key: \(defaultKey.path)")
      if let pub = inspection.pubKey {
        if let type = inspection.keyType {
          print("  Key Type:    \(type)")
        }
        print("  Public Key:  \(pub)")
        if let fp = inspection.fingerprint {
          print("  Fingerprint: \(fp)")
        }
      }
    } else {
      print("  Private Key: Not Found (\(defaultKey.path))")
      print("  To generate a key, run: invariants key generate")
    }

    if inspection.backupCount > 0 {
      let sshDir = defaultKey.deletingLastPathComponent()
      print("  Backups:     \(inspection.backupCount) archived rotation backup(s) in \(sshDir.path)")
    }
    return inspection.pubKey
  }

  private static func statusProjectIfAvailable(for pubKey: String?) {
    print("")
    guard let repoRoot = try? RepoLocator.discover() else {
      print("[Active Project]")
      print("  Not inside an Invariants repository.")
      return
    }

    RepoLocator.withRepoRoot(repoRoot) {
      print("[Active Project: \(repoRoot.lastPathComponent)]")
      let lockURL = RegistryManager.registryURL()
      let signersURL = RegistryManager.allowedSignersURL()

      let hasLock = FileManager.default.fileExists(atPath: lockURL.path)
      let hasSigners = FileManager.default.fileExists(atPath: signersURL.path)
      if hasLock && hasSigners {
        do {
          let lockData = try Data(contentsOf: lockURL)
          let reg = try CanonicalJSON.parse(data: lockData)
          print("  Registry:    version \(reg.version) (\(reg.rules.count) active rule(s))")
          print("  Trunk:       \(reg.defaultBranch)")
        } catch {
          print("  Registry:    Error reading registry.lock: \(error.localizedDescription)")
        }

        if let pubKey {
          do {
            let signersFile = try AllowedSignersFile.read(from: signersURL)
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
          } catch {
            print("  Your Status: ⚠️ Error reading invariants/allowed_signers: \(error.localizedDescription)")
          }
        } else {
          print("  Your Status: ℹ️ Read-Only (No local key to check against allowed_signers)")
        }
      } else {
        print("  Invariants:  Not initialized in this repository.")
        print("  To initialize, run: invariants init")
      }
    }
  }

  package static func rotate() async throws {
    let defaultKey = SystemEnvironment.defaultSigningKeyURL
    guard FileManager.default.fileExists(atPath: defaultKey.path) else {
      throw KeyLifecycleError.keyNotFound(defaultKey.path)
    }

    print("Touch your Touch ID sensor to enroll a new hardware signing key in Apple Secure Enclave...")
    let (backupKey, _) = try await HardwareKeyManager.rotateHardwareKey(at: defaultKey)
    let pubURL = defaultKey.appendingPathExtension("pub")

    print("✓ Local key rotated successfully.")
    print("Old key archived to: \(backupKey.path)")
    let newPub = try pubURL.readTrimmedUTF8()
    if !newPub.isEmpty {
      print("\nNew Public Key:\n  \(newPub)\n")
    }

    print("Next steps:")
    print("To update this key in your project(s), run in each relevant repository:")
    print("    invariants signers rotate")
    print("(or share the new public key above with your repository lead).")
  }

  package static func delete(skipConfirmation: Bool = false) async throws {
    let defaultKey = SystemEnvironment.defaultSigningKeyURL
    let defaultPub = defaultKey.appendingPathExtension("pub")

    guard
      FileManager.default.fileExists(atPath: defaultKey.path) || FileManager.default.fileExists(atPath: defaultPub.path)
    else {
      print("No signing key found at \(defaultKey.path).")
      return
    }

    if !skipConfirmation && TerminalPrompt.isInteractive {
      let confirmed = TerminalPrompt.promptConfirmation(
        question: "Are you sure you want to delete \(defaultKey.path)?",
        default: false
      )
      guard confirmed else {
        print("Aborted.")
        return
      }
    }

    print("Touch your Touch ID sensor to confirm deleting your Apple Secure Enclave signing key...")
    try await HardwareKeyManager.deleteHardwareKey(at: defaultKey)

    print("✓ Deleted local signing key: \(defaultKey.path)")
    print("\n⚠️  Important Reminder:")
    print("This removed the private key from this Mac.")
    print("If this key was registered in any Git projects, remember to have a team lead run:")
    print("    invariants signers revoke \"<identity>\"")
    print("in those repositories to remove its signing authorization.")
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
          print("Aborted.")
          return
        }
      }
    }

    try await rotate()
    print("✓ Generated fresh Secure Enclave signing key: \(defaultKey.path)")
  }

  package static func clean(skipConfirmation: Bool = false) throws {
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

    if !skipConfirmation && TerminalPrompt.isInteractive {
      let confirmed = TerminalPrompt.promptConfirmation(
        question: "Found \(backups.count) backup file(s) in \(sshDir.path). Delete them?",
        default: false
      )
      guard confirmed else {
        print("Aborted.")
        return
      }
    }

    let count = try HardwareKeyManager.cleanBackups(in: sshDir)
    print("✓ Cleaned up \(count) rotation backup file(s) from \(sshDir.path).")
  }
}
