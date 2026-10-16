public import Foundation

/// Errors related to registry loading, serialization, signing, and verification.
public enum RegistryError: Error, Equatable, Sendable, CustomStringConvertible {
  case fileNotFound(URL)
  case signatureNotFound(URL)
  case signatureInvalid(String)
  case engineVersionMismatch(required: String, installed: String)
  case invalidCanonicalJSON(String)
  case decodingFailed(String)
  case encodingFailed(String)

  public var description: String {
    switch self {
    case .fileNotFound(let url):
      return "Registry file not found: \(url.path)"
    case .signatureNotFound(let url):
      return "Signature file not found: \(url.path)"
    case .signatureInvalid(let details):
      return "Invalid cryptographic signature: \(details)"
    case .engineVersionMismatch(let required, let installed):
      return "Engine version mismatch: required '\(required)', installed '\(installed)'"
    case .invalidCanonicalJSON(let details):
      return "Invalid canonical JSON: \(details)"
    case .decodingFailed(let details):
      return "Failed to decode registry: \(details)"
    case .encodingFailed(let details):
      return "Failed to encode registry: \(details)"
    }
  }
}
