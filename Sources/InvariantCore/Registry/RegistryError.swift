public import Foundation

/// Errors related to registry loading, serialization, signing, and verification.
public enum RegistryError: Error, Equatable, Sendable {
  case fileNotFound(URL)
  case signatureNotFound(URL)
  case signatureInvalid(String)
  case engineVersionMismatch(required: String, installed: String)
  case invalidCanonicalJSON(String)
  case decodingFailed(String)
  case encodingFailed(String)
}
