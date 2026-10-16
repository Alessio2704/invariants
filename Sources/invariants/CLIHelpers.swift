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

  /// Resolves the dedicated Invariants signing key.
  /// 1. Uses explicit customPath if passed and valid.
  /// 2. Uses dedicated default key at ~/.ssh/invariants_ed25519 (or .pub).
  /// 3. Returns nil if not found.
  static func resolveSigningKey(customPath: String? = nil, repoRoot: URL? = nil) -> URL? {
    if let customPath, !customPath.isEmpty {
      let url = URL(fileURLWithPath: (customPath as NSString).expandingTildeInPath)
      if FileManager.default.fileExists(atPath: url.path) {
        return url
      }
    }

    let defaultKey = SystemEnvironment.defaultSigningKeyURL
    if FileManager.default.fileExists(atPath: defaultKey.path) {
      return defaultKey
    }
    let defaultPub = defaultKey.appendingPathExtension("pub")
    if FileManager.default.fileExists(atPath: defaultPub.path) {
      return defaultPub
    }

    return nil
  }

  /// Prompts user to select or provide a signing key during interactive init/commands.
  static func promptForSigningKey(customPath: String? = nil, repoRoot: URL? = nil) -> URL? {
    if let resolved = resolveSigningKey(customPath: customPath, repoRoot: repoRoot) {
      return resolved
    }

    if isInteractive {
      let custom = prompt(
        question: "Invariants signing key not found at ~/.ssh/invariants_ed25519. Enter path to key"
      )
      if !custom.isEmpty {
        let expanded = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        if FileManager.default.fileExists(atPath: expanded.path) {
          return expanded
        }
      }
    }

    return nil
  }

  /// Installed engine version.
  static let engineVersion = "1.0.0"
}
