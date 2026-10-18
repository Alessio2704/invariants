import Foundation
import InvariantCore

/// Resolves or prompts for the cryptographic signing key for repository operations.
enum SigningKeyResolver {
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

    if CLIUtil.isInteractive {
      let shouldGenerate = TerminalPrompter.shared.promptConfirmation(
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

      let custom = TerminalPrompter.shared.prompt(
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
}
