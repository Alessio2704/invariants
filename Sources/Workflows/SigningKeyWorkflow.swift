import Core
package import Foundation
import Terminal

/// Interactive workflow responsible for resolving, generating, or prompting for signing keys.
package enum SigningKeyWorkflow {
  /// Resolves the signing key from explicit path or default location, prompting the user interactively if missing.
  package static func resolveOrPrompt(customPath: String? = nil) async throws -> URL? {
    if let customPath, !customPath.isEmpty {
      let url = URL(fileURLWithPath: (customPath as NSString).expandingTildeInPath)
      if FileManager.default.fileExists(atPath: url.path) {
        return url
      }
      return nil
    }

    if let defaultKey = SigningKeyResolver.resolveSigningKey() {
      return defaultKey
    }

    let shouldGenerate = try TerminalPrompt.promptConfirmation(
      question: "Signing key not found at ~/\(SystemPaths.defaultKeySubpath). Generate a Touch ID hardware key now?",
      default: true
    )
    if shouldGenerate {
      return try await HardwareKeyWorkflow.generate(force: false)
    }

    let custom = try TerminalPrompt.prompt(
      question: "Enter path to an existing SSH private key (or press Enter to cancel)"
    )
    if !custom.isEmpty {
      let expanded = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
      if FileManager.default.fileExists(atPath: expanded.path) {
        return expanded
      }
    }

    return nil
  }
}
