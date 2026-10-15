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

  /// Whether current process has an interactive standard input terminal attached.
  static var isInteractive: Bool {
    isatty(FileHandle.standardInput.fileDescriptor) != 0
  }

  /// Prompts user with a question and returns trimmed response, or defaultValue if blank.
  static func prompt(question: String, default defaultValue: String? = nil) -> String {
    if let defaultValue {
      print("\(question) [\(defaultValue)]: ", terminator: "")
    } else {
      print("\(question): ", terminator: "")
    }
    fflush(stdout)
    guard let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else {
      return defaultValue ?? ""
    }
    return line
  }

  /// Prompts user for a yes/no confirmation.
  static func promptConfirmation(question: String, default defaultYes: Bool = false) -> Bool {
    let hint = defaultYes ? "[Y/n]" : "[y/N]"
    print("\(question) \(hint): ", terminator: "")
    fflush(stdout)
    guard let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
      return defaultYes
    }
    if line.isEmpty { return defaultYes }
    return line == "y" || line == "yes"
  }

  /// Returns all public key candidate files found in ~/.ssh/*.pub.
  static func discoverCandidateKeys() -> [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let sshDir = home.appendingPathComponent(".ssh")
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: sshDir.path) else {
      return []
    }
    var keys: [URL] = []
    for file in files.sorted() where file.hasSuffix(".pub") {
      let pubURL = sshDir.appendingPathComponent(file)
      if FileManager.default.fileExists(atPath: pubURL.path) {
        keys.append(pubURL)
      }
    }
    return keys
  }

  /// Resolves the owner's SSH public key for signing without silent assumptions.
  /// 1. Uses explicit customPath if passed and valid.
  /// 2. Reads `git config user.signingkey` if configured and valid.
  /// 3. Returns nil if neither is configured. (Interactive prompting happens in promptForSigningKey).
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

    return nil
  }

  /// Prompts user to select or provide a signing key during interactive init/commands.
  static func promptForSigningKey(customPath: String? = nil, repoRoot: URL? = nil) -> URL? {
    if let resolved = resolveSigningKey(customPath: customPath, repoRoot: repoRoot) {
      if isInteractive {
        let confirm = promptConfirmation(
          question: "Use detected signing key (\(resolved.path))?",
          default: true
        )
        if confirm {
          return resolved
        }
      } else {
        return resolved
      }
    }

    let candidates = discoverCandidateKeys()
    if isInteractive {
      if !candidates.isEmpty {
        print("\nDiscovered SSH public keys:")
        for (idx, keyURL) in candidates.enumerated() {
          print("  [\(idx + 1)] \(keyURL.path)")
        }
        let choice = prompt(question: "Select key number or enter custom public key path")
        if let num = Int(choice), num >= 1, num <= candidates.count {
          return candidates[num - 1]
        }
        if !choice.isEmpty {
          let expanded = URL(fileURLWithPath: (choice as NSString).expandingTildeInPath)
          if FileManager.default.fileExists(atPath: expanded.path) {
            return expanded
          }
        }
      } else {
        let custom = prompt(question: "Enter path to SSH public key (.pub)")
        if !custom.isEmpty {
          let expanded = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
          if FileManager.default.fileExists(atPath: expanded.path) {
            return expanded
          }
        }
      }
    }

    return nil
  }

  /// Installed engine version.
  static let engineVersion = "1.0.0"
}
