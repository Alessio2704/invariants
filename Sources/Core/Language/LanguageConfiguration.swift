import Foundation

/// Dynamic contract for a language's strongly-typed compile-time configuration.
public protocol LanguageConfiguration: Sendable, Codable {
  func isEqualTo(_ other: any LanguageConfiguration) -> Bool
  func toCanonicalJSON() -> String?
}

extension LanguageConfiguration where Self: Equatable {
  public func isEqualTo(_ other: any LanguageConfiguration) -> Bool {
    guard let otherTyped = other as? Self else { return false }
    return self == otherTyped
  }

  public func toCanonicalJSON() -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(self) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
