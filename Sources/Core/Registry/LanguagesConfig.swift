import Foundation

/// Named AST units declared in registry.lock under "ast".
public struct ASTConfig: Sendable {
  private var storage: [SupportedLanguage: [String: any LanguageConfiguration]]

  public init() {
    self.storage = [:]
  }

  // periphery:ignore
  public init(storage: [SupportedLanguage: [String: any LanguageConfiguration]]) {
    self.storage = storage
  }

  // periphery:ignore
  public var isEmpty: Bool {
    storage.values.allSatisfy { $0.isEmpty }
  }

  public var configuredLanguages: [SupportedLanguage] {
    storage.filter { !$0.value.isEmpty }.keys.sorted(by: { $0.rawValue < $1.rawValue })
  }

  // periphery:ignore
  public func isConfigured(_ language: SupportedLanguage) -> Bool {
    guard let units = storage[language] else { return false }
    return !units.isEmpty
  }

  public func units(for language: SupportedLanguage) -> [String] {
    storage[language]?.keys.sorted() ?? []
  }

  /// Strongly-typed subscript for accessing and modifying language configs.
  public subscript<L: LanguageSpec>(_ spec: L.Type) -> [String: L.Config] {
    get {
      guard let langUnits = storage[L.language] else { return [:] }
      var result: [String: L.Config] = [:]
      for (unitName, config) in langUnits {
        if let typed = config as? L.Config {
          result[unitName] = typed
        }
      }
      return result
    }
    set {
      if newValue.isEmpty {
        storage.removeValue(forKey: L.language)
      } else {
        storage[L.language] = newValue
      }
    }
  }

  /// Polymorphic subscript for accessing and modifying language configs by language key.
  public subscript(language: SupportedLanguage) -> [String: any LanguageConfiguration] {
    get {
      storage[language] ?? [:]
    }
    set {
      if newValue.isEmpty {
        storage.removeValue(forKey: language)
      } else {
        storage[language] = newValue
      }
    }
  }

  // periphery:ignore
  /// Returns canonical JSON string representation for a language's AST units.
  public func canonicalJSON(for language: SupportedLanguage) -> String? {
    guard let units = storage[language], !units.isEmpty else { return nil }
    let sortedUnitKeys = units.keys.sorted()
    var lines: [String] = ["{"]
    for (idx, unitKey) in sortedUnitKeys.enumerated() {
      guard let config = units[unitKey], let configJSON = config.toCanonicalJSON() else { continue }
      let comma = (idx < sortedUnitKeys.count - 1) ? "," : ""
      lines.append("      \"\(CanonicalJSON.escape(unitKey))\": \(configJSON)\(comma)")
    }
    lines.append("    }")
    return lines.joined(separator: "\n")
  }
}

// periphery:ignore
public typealias LanguagesConfig = ASTConfig

extension ASTConfig: Equatable {
  public static func == (lhs: ASTConfig, rhs: ASTConfig) -> Bool {
    let lhsLangs = lhs.configuredLanguages
    let rhsLangs = rhs.configuredLanguages
    guard lhsLangs == rhsLangs else { return false }
    for lang in lhsLangs {
      let lhsUnits = lhs.storage[lang] ?? [:]
      let rhsUnits = rhs.storage[lang] ?? [:]
      guard lhsUnits.count == rhsUnits.count else { return false }
      for (unitName, lhsConfig) in lhsUnits {
        guard let rhsConfig = rhsUnits[unitName] else { return false }
        guard lhsConfig.isEqualTo(rhsConfig) else { return false }
      }
    }
    return true
  }
}

extension ASTConfig: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: SupportedLanguage.self)
    var newStorage: [SupportedLanguage: [String: any LanguageConfiguration]] = [:]

    for lang in container.allKeys {
      switch lang {
      case .swift:
        let swiftUnits = try container.decode([String: SwiftLanguage.Config].self, forKey: lang)
        newStorage[lang] = swiftUnits
      case .ts:
        let tsUnits = try container.decode([String: TypeScriptLanguage.Config].self, forKey: lang)
        newStorage[lang] = tsUnits
      }
    }
    self.storage = newStorage
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: SupportedLanguage.self)
    for lang in configuredLanguages {
      switch lang {
      case .swift:
        let swiftUnits = self[SwiftLanguage.self]
        if !swiftUnits.isEmpty {
          try container.encode(swiftUnits, forKey: lang)
        }
      case .ts:
        let tsUnits = self[TypeScriptLanguage.self]
        if !tsUnits.isEmpty {
          try container.encode(tsUnits, forKey: lang)
        }
      }
    }
  }
}
