import ArgumentParser
import Foundation
import InvariantCore

struct StatusCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "Report invariants configuration, signatures, floor, and rule statuses."
  )

  @Option(name: .long, help: "Explicit repository root path (used in testing).")
  var repoPath: String?

  func run() async throws {
    let repoRootURL: URL
    if let repoPath {
      repoRootURL = URL(fileURLWithPath: repoPath)
    } else if let found = CLIHelpers.findRepoRoot() {
      repoRootURL = found
    } else {
      fputs("Error: Not inside a git repository.\n", stderr)
      throw ExitCode(1)
    }

    let env = SystemEnvironment.standard
    let registryManager = RegistryManager(environment: env)
    let fingerprintEngine = FingerprintEngine()
    let fm = FileManager.default

    print("Invariants Status")
    print("─────────────────")

    // 1. Registry & Signature
    var registry: Registry?
    do {
      let loaded = try await registryManager.loadAndVerify(
        repoRoot: repoRootURL,
        installedEngineVersion: CLIHelpers.engineVersion
      )
      registry = loaded
      print("Engine:      \(CLIHelpers.engineVersion) (satisfies range '\(loaded.engine)')")
      print("Signature:   ✓ valid (verified against allowed_signers)")
      print("Registry:    v\(loaded.version) (repo: \(loaded.repo))")
    } catch let regErr {
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
    }

    // 2. Floor
    if let reg = registry {
      let floorFile = env.floorsDirectoryURL.appendingPathComponent(reg.repo)
      let floorContent = try? String(contentsOf: floorFile, encoding: .utf8)
      if fm.fileExists(atPath: floorFile.path), let content = floorContent {
        let floorVal = content.trimmingCharacters(in: .whitespacesAndNewlines)
        print("Root Floor:  \(floorVal) (registry is v\(reg.version))")
      } else {
        print("Root Floor:  none recorded")
      }
    }

    // 3. Hook Shims Integrity
    let preCommitURL = repoRootURL.appendingPathComponent(".githooks/pre-commit")
    let prePushURL = repoRootURL.appendingPathComponent(".githooks/pre-push")
    let preCommitOk = (try? String(contentsOf: preCommitURL, encoding: .utf8))?.contains("invariants check") ?? false
    let prePushOk = (try? String(contentsOf: prePushURL, encoding: .utf8))?.contains("invariants check") ?? false

    if preCommitOk && prePushOk {
      print("Hook Shims:  ✓ intact (.githooks/pre-commit, pre-push)")
    } else {
      print("Hook Shims:  ✗ modified or missing! Shims must invoke 'invariants check'")
    }

    print("\nRules:")
    guard let reg = registry else { return }

    // Active rules
    for (ruleId, signedHash) in reg.rules.sorted(by: { $0.key < $1.key }) {
      let ruleDir = repoRootURL.appendingPathComponent("invariants/rules/\(ruleId)")
      if !fm.fileExists(atPath: ruleDir.path) {
        print("  ✗ \(ruleId): missing on disk")
        continue
      }

      let workingHash: String?
      do {
        workingHash = try await fingerprintEngine.computeFingerprint(repoRoot: repoRootURL, ruleId: ruleId)
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
    let rulesDir = repoRootURL.appendingPathComponent("invariants/rules")
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
