import Foundation
import InvariantCore

enum CLIHelpers {
  /// Locates the enclosing git repository root directory from the current working directory.
  static func findRepoRoot(
    from startURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  ) -> URL? {
    var current = startURL.standardizedFileURL
    while true {
      let gitMarker = current.appendingPathComponent(".git")
      if FileManager.default.fileExists(atPath: gitMarker.path) {
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
  /// 1. Uses explicit customPath if passed.
  /// 2. Reads `git config user.signingkey` (standard Git signing key configuration).
  /// 3. Falls back to discovering any public key in `~/.ssh/*.pub`.
  static func resolveSigningKey(customPath: String? = nil, repoRoot: URL? = nil) -> URL? {
    if let customPath, !customPath.isEmpty {
      let url = URL(fileURLWithPath: (customPath as NSString).expandingTildeInPath)
      if FileManager.default.fileExists(atPath: url.path) {
        return url
      }
    }

    // Query git config user.signingkey
    let pipe = Pipe()
    let process = Process()
    process.executableURL = SubprocessRunner.gitURL
    var args = ["config", "--get", "user.signingkey"]
    if let repoRoot {
      args = ["-C", repoRoot.path, "config", "--get", "user.signingkey"]
    }
    process.arguments = args
    process.standardOutput = pipe
    process.standardError = Pipe()
    if (try? process.run()) != nil {
      process.waitUntilExit()
      if process.terminationStatus == 0 {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let rawStr = String(bytes: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let keyStr = rawStr, !keyStr.isEmpty {
          let path = (keyStr as NSString).expandingTildeInPath
          let url = URL(fileURLWithPath: path)
          if FileManager.default.fileExists(atPath: url.path) {
            return url
          }
        }
      }
    }

    // Fallback: discover any .pub file in ~/.ssh/
    let home = FileManager.default.homeDirectoryForCurrentUser
    let sshDir = home.appendingPathComponent(".ssh")
    if let files = try? FileManager.default.contentsOfDirectory(atPath: sshDir.path) {
      for file in files.sorted() where file.hasSuffix(".pub") {
        let pubURL = sshDir.appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: pubURL.path) {
          return pubURL
        }
      }
    }

    return nil
  }

  /// Installed engine version.
  static let engineVersion = "1.0.0"
}
