import Foundation
import InvariantCore

enum CLIError: LocalizedError, Equatable {
  case notInsideGitRepository

  var errorDescription: String? {
    switch self {
    case .notInsideGitRepository:
      return "Not inside a git repository."
    }
  }
}

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

  /// Locates the enclosing git repository root directory or throws an error.
  static func requireRepoRoot() throws(CLIError) -> URL {
    guard let root = findRepoRoot() else {
      throw CLIError.notInsideGitRepository
    }
    return root
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
  /// 2. Uses dedicated default key at ~/.ssh/invariants_p256 (or .pub).
  /// 3. Returns nil if not found.
  static func resolveSigningKey(customPath: String? = nil) -> URL? {
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

    return nil
  }

  /// Prompts user to select or provide a signing key during interactive init/commands.
  static func promptForSigningKey(customPath: String? = nil) async -> URL? {
    if let resolved = resolveSigningKey(customPath: customPath) {
      return resolved
    }

    if isInteractive {
      let shouldGenerate = promptConfirmation(
        question: "Signing key not found at ~/\(SystemPaths.defaultKeySubpath). Generate a Touch ID hardware key now?",
        default: true
      )
      if shouldGenerate {
        do {
          return try await KeyCommand.generateHardwareKey(force: false, showContextualStatus: false)
        } catch {
          fputs("Warning: Could not generate Secure Enclave key: \(error)\n", stderr)
        }
      }

      let custom = prompt(
        question: "Enter path to an existing SSH private key (or press Enter to cancel)"
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
  static var engineVersion: String { EngineVersion.current }
}

struct CLIInteractivePrompter: InteractivePrompter {
  func prompt(question: String) -> String {
    CLIHelpers.prompt(question: question, default: nil)
  }

  func prompt(question: String, default defaultValue: String?) -> String {
    CLIHelpers.prompt(question: question, default: defaultValue)
  }

  func promptConfirmation(question: String, default defaultYes: Bool) -> Bool {
    CLIHelpers.promptConfirmation(question: question, default: defaultYes)
  }

  func printLine(_ message: String) {
    print(message)
  }
}
