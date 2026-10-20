import Core
package import Foundation

/// Workflow responsible for resolving signing keys from explicit paths or default location.
package enum SigningKeyWorkflow {
  /// Resolves the signing key from an explicit path or default location.
  /// Returns nil if no key exists at the resolved path.
  package static func resolve(customPath: String? = nil) -> URL? {
    if let customPath {
      return SigningKeyResolver.resolveCustomSigningKey(customPath: customPath)
    }
    return SigningKeyResolver.resolveDefaultSigningKey()
  }
}
