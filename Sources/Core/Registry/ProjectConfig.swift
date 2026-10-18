import Foundation

/// Dynamic project-wide analysis inputs declared in registry.lock.
public struct ProjectConfig: Sendable {
  private var storage: [SupportedLanguage: any LanguageConfiguration]

  public init() {
    self.storage = [:]
  }

  public var isEmpty: Bool {
    storage.isEmpty
  }

  public var configuredLanguages: [SupportedLanguage] {
    storage.keys.sorted(by: { $0.rawValue < $1.rawValue })
  }

  public func isConfigured(_ language: SupportedLanguage) -> Bool {
    storage[language] != nil
  }

  /// Strongly-typed subscript for accessing and modifying language configs.
  public subscript<L: LanguageSpec>(_ spec: L.Type) -> L.Config? {
    get {
      storage[L.language] as? L.Config
    }
    set {
      if let newValue {
        storage[L.language] = newValue
      } else {
        storage.removeValue(forKey: L.language)
      }
    }
  }

  /// Polymorphic subscript for accessing and modifying language configs by language key.
  public subscript(language: SupportedLanguage) -> (any LanguageConfiguration)? {
    get {
      storage[language]
    }
    set {
      if let newValue {
        storage[language] = newValue
      } else {
        storage.removeValue(forKey: language)
      }
    }
  }

  /// Returns canonical JSON string representation for a language's config.
  public func canonicalJSON(for language: SupportedLanguage) -> String? {
    storage[language]?.toCanonicalJSON()
  }
}

extension ProjectConfig: Equatable {
  public static func == (lhs: ProjectConfig, rhs: ProjectConfig) -> Bool {
    guard lhs.storage.count == rhs.storage.count else { return false }
    for (lang, config) in lhs.storage {
      guard let rhsConfig = rhs.storage[lang] else { return false }
      guard config.isEqualTo(rhsConfig) else { return false }
    }
    return true
  }
}

extension ProjectConfig: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: SupportedLanguage.self)
    var newStorage: [SupportedLanguage: any LanguageConfiguration] = [:]

    for lang in container.allKeys {
      let subDecoder = try container.superDecoder(forKey: lang)
      if let decoded = try lang.spec.decodeConfig(from: subDecoder) {
        newStorage[lang] = decoded
      }
    }
    self.storage = newStorage
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: SupportedLanguage.self)
    for lang in configuredLanguages {
      guard let config = storage[lang] else { continue }
      let subEncoder = container.superEncoder(forKey: lang)
      try lang.spec.encodeConfig(config, to: subEncoder)
    }
  }
}
