import ArgumentParser
import Core
import Foundation

struct StatusCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "Report invariants configuration, signatures, floor, and rule statuses."
  )

  func run() async throws {
    let repoRoot = try RepoLocator.discover()
    await RepoLocator.withRepoRoot(repoRoot) {
      let fm = FileManager.default

      print("Invariants Status")
      print("─────────────────")

      // 1. Registry & Signature
      var registry: Registry?
      do {
        let loaded = try await RegistryManager.loadAndVerify(
          installedEngineVersion: EngineVersion.current
        )
        registry = loaded
        print("Engine:      \(EngineVersion.current) (satisfies range '\(loaded.engine)')")
        print("Signature:   ✓ valid (verified against allowed_signers)")
        print("Registry:    v\(loaded.version)")
      } catch let regErr as RegistryError {
        switch regErr {
        case .signatureInvalid:
          print("Signature:   ✗ INVALID")
        case .signatureNotFound:
          print("Signature:   ✗ signature file missing (registry.lock.sig)")
        case .engineVersionMismatch(let req, let inst):
          print("Engine:      ✗ installed \(inst) does not satisfy \(req)")
        default:
          print("Registry:    ✗ error: \(regErr)")
        }
      } catch {
        print("Registry:    ✗ error: \(error)")
      }

      // 2. Floor
      if let reg = registry {
        if let histFloor = try? await FloorGuard.checkHistory(currentVersion: reg.version) {
          print("Git Floor:   v\(histFloor) (history max)")
        }
      }

      // 3. Git Hooks
      let candidateHooks = [
        ".githooks/pre-commit",
        ".githooks/pre-push",
        ".git/hooks/pre-commit",
        ".git/hooks/pre-push",
      ]
      let activeHooks = candidateHooks.filter { rel in
        let url = RepoLocator.current.appendingPathComponent(rel)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
          return try url.readUTF8().contains("invariants check")
        } catch {
          return false
        }
      }

      if !activeHooks.isEmpty {
        print("Git Hooks:   ✓ active (\(activeHooks.joined(separator: ", ")))")
      } else {
        print("Git Hooks:   none configured (optional: invoke 'invariants check' in pre-commit)")
      }

      print("\nRules:")
      guard let reg = registry else { return }

      // Active rules
      for (ruleId, signedHash) in reg.rules.sorted(by: { $0.key < $1.key }) {
        let ruleDir = RepoLocator.current.appendingPathComponent("invariants/rules/\(ruleId)")
        if !fm.fileExists(atPath: ruleDir.path) {
          print("  ✗ \(ruleId): missing on disk")
          continue
        }

        let workingHash: String?
        do {
          workingHash = try await FingerprintEngine.computeFingerprint(ruleId: ruleId)
        } catch {
          workingHash = nil
        }

        if workingHash == signedHash {
          print("  ✓ \(ruleId): active (\(signedHash.prefix(7)))")
        } else {
          let sH = signedHash.prefix(7)
          let wH = workingHash?.prefix(7) ?? "unknown"
          print("  ✎ \(ruleId): modified since signed (\(sH) → \(wH))")
        }
      }

      // Draft rules
      let rulesDir = RepoLocator.current.appendingPathComponent("invariants/rules")
      if let allDirs = try? fm.contentsOfDirectory(atPath: rulesDir.path) {
        for dir in allDirs.sorted() where !reg.rules.keys.contains(dir) && !dir.hasPrefix(".") {
          let dURL = rulesDir.appendingPathComponent(dir)
          var isDir: ObjCBool = false
          if fm.fileExists(atPath: dURL.path, isDirectory: &isDir), isDir.boolValue {
            print("  ○ \(dir): draft")
          }
        }
      }
    }
  }
}
