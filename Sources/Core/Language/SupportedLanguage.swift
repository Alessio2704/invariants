public import Foundation

/// The set of target languages supported by Invariants for static analysis and rule enforcement.
public enum SupportedLanguage: String, CodingKey, Sendable, Codable, CaseIterable {
  case swift
  case ts

  public var stringValue: String { rawValue }
  public init?(stringValue: String) { self.init(rawValue: stringValue) }
  public var intValue: Int? { nil }
  public init?(intValue: Int) { nil }

  public var spec: any AnyLanguageSpec.Type {
    switch self {
    case .swift: return SwiftLanguage.self
    case .ts: return TypeScriptLanguage.self
    }
  }
}

/// Typealias preserving target terminology across manifest models.
public typealias TargetLanguage = SupportedLanguage

extension SupportedLanguage {
  /// Checks if a relative path should be skipped across any supported language or universal system path.
  public static func shouldSkipAny(relativePath: String) -> Bool {
    for universal in SystemPaths.universalIgnoredPaths
    where SwiftLanguage.matchesIgnoredPath(relativePath: relativePath, ignoredPattern: universal) {
      return true
    }
    return allCases.contains { $0.spec.shouldSkip(relativePath: relativePath) }
  }

  /// Checks if a file URL should be skipped across any supported language or universal system path.
  public static func shouldSkipAny(url: URL) -> Bool {
    allCases.contains { $0.spec.shouldSkip(url: url) }
  }

  /// Detects languages with source files present in the repository root.
  public static func detectLanguages() -> [SupportedLanguage] {
    allCases.filter { $0.spec.hasSources() }
  }
}
