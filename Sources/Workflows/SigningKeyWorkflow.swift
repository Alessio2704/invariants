import Core
package import Foundation
import Terminal

/// Interactive workflow responsible for resolving, generating, or prompting for signing keys.
package enum SigningKeyWorkflow {
  /// Resolves the signing key from explicit path or default location, prompting the user interactively if missing.
  package static func resolveOrPrompt(customPath: String? = nil) async -> URL? {
    if let resolved = SigningKeyResolver.resolveSigningKey(customPath: customPath) {
      return resolved
    }

    guard TerminalPrompt.isInteractive else {
      return nil
    }

    let shouldGenerate = TerminalPrompt.promptConfirmation(
      question: "Signing key not found at ~/\(SystemPaths.defaultKeySubpath). Generate a Touch ID hardware key now?",
      default: true
    )
    if shouldGenerate {
      do {
        return try await HardwareKeyWorkflow.generate(force: false)
      } catch {
        fputs("Warning: Could not generate Secure Enclave key: \(error)\n", stderr)
      }
    }

    let custom = TerminalPrompt.prompt(
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
