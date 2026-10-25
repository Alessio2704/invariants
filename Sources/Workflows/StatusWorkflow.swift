import Core
import Foundation
import Terminal

/// Interactive CLI workflow to report engine and registry statuses.
package enum StatusWorkflow {
  /// Displays the invariants engine configuration, registry status, floor, and rule statuses.
  package static func execute() async {
    let fm = FileManager.default

    Terminal.header("Invariants Status")

    // 1. Registry & Signature
    var registry: Registry?
    do {
      let loaded = try await RegistryManager.loadAndVerify()
      registry = loaded
      Terminal.field("Engine:", value: "\(EngineVersion.current) (satisfies range '\(loaded.engine)')")
      Terminal.field("Signature:", value: "✓ valid (verified against allowed_signers)")
      Terminal.field("Registry:", value: "v\(loaded.version)")
    } catch let regErr {
      switch regErr {
      case .signatureInvalid:
        Terminal.field("Signature:", value: "✗ INVALID")
      case .signatureNotFound:
        Terminal.field("Signature:", value: "✗ signature file missing (registry.lock.sig)")
      case .engineVersionMismatch(let req, let inst):
        Terminal.field("Engine:", value: "✗ installed \(inst) does not satisfy \(req)")
      default:
        Terminal.field("Registry:", value: "✗ error: \(regErr)")
      }
    }

    // 2. Floor
    if let reg = registry {
      if let histFloor = try? await FloorGuard.checkHistory(currentVersion: reg.version) {
        Terminal.field("Git Floor:", value: "v\(histFloor) (history max)")
      }
    }

    Terminal.line("\nRules:")
    guard let reg = registry else { return }

    // Active rules
    for (ruleId, signedHash) in reg.rules.sorted(by: { $0.key < $1.key }) {
      let ruleDir = RepoLocator.current.appendingPathComponent("invariants/rules/\(ruleId)")
      if !fm.fileExists(atPath: ruleDir.path) {
        Terminal.statusItem("✗", label: ruleId, detail: "missing on disk")
        continue
      }

      let workingHash: String?
      do {
        workingHash = try await FingerprintEngine.computeFingerprint(ruleId: ruleId)
      } catch {
        workingHash = nil
      }

      if workingHash == signedHash {
        Terminal.statusItem("✓", label: ruleId, detail: "active (\(signedHash.prefix(7)))")
      } else {
        let sH = signedHash.prefix(7)
        let wH = workingHash?.prefix(7) ?? "unknown"
        Terminal.statusItem("✎", label: ruleId, detail: "modified since signed (\(sH) → \(wH))")
      }
    }

    // Draft rules
    let rulesDir = RepoLocator.current.appendingPathComponent("invariants/rules")
    if let allDirs = try? fm.contentsOfDirectory(atPath: rulesDir.path) {
      for dir in allDirs.sorted() where !reg.rules.keys.contains(dir) && !dir.hasPrefix(".") {
        let dURL = rulesDir.appendingPathComponent(dir)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dURL.path, isDirectory: &isDir), isDir.boolValue {
          Terminal.statusItem("○", label: dir, detail: "draft")
        }
      }
    }
  }
}
