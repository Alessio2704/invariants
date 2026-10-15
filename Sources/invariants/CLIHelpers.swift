import Foundation
import InvariantCore

enum CLIHelpers {
  /// Discovers git repository root by traversing upward.
  static func findRepoRoot(startingAt startURL: URL? = nil) -> URL? {
    let start = startURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    var current = start.standardizedFileURL
    let fm = FileManager.default
    while true {
      let gitDir = current.appendingPathComponent(".git")
      if fm.fileExists(atPath: gitDir.path) {
        return current
      }
      let parent = current.deletingLastPathComponent()
      if parent.path == current.path {
        return nil
      }
      current = parent
    }
  }

  /// Resolves the owner's SSH public key for signing.
  static func resolveSigningKey(customPath: String? = nil) -> URL? {
    if let customPath, !customPath.isEmpty {
      let url = URL(fileURLWithPath: customPath)
      if FileManager.default.fileExists(atPath: url.path) {
        return url
      }
    }

    let home = FileManager.default.homeDirectoryForCurrentUser
    let sshDir = home.appendingPathComponent(".ssh")
    var candidates = [
      sshDir.appendingPathComponent("id_ed25519_sk.pub"),
      sshDir.appendingPathComponent("id_ed25519.pub"),
      sshDir.appendingPathComponent("id_ecdsa_sk.pub"),
      sshDir.appendingPathComponent("id_ed25519"),
    ]
    if let sshFiles = try? FileManager.default.contentsOfDirectory(atPath: sshDir.path) {
      for file in sshFiles where file.hasPrefix("secretive_") && file.hasSuffix(".pub") {
        candidates.insert(sshDir.appendingPathComponent(file), at: 0)
      }
    }
    for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
      return candidate
    }
    return nil
  }

  /// Installed engine version.
  static let engineVersion = "1.0.0"
}
