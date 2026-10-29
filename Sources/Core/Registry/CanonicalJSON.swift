public import Foundation

/// Canonical JSON formatting and parsing for `Registry`.
public enum CanonicalJSON {
  /// Serializes a `Registry` into deterministic canonical JSON format.
  public static func serialize(_ registry: Registry) -> String {
    var lines: [String] = ["{"]

    // 1. "ast" (nested by sorted language key, then sorted unit name)
    let astLangs = registry.ast.configuredLanguages
    if astLangs.isEmpty {
      lines.append("  \"ast\": {},")
    } else {
      lines.append("  \"ast\": {")
      for (langIdx, lang) in astLangs.enumerated() {
        let langComma = (langIdx < astLangs.count - 1) ? "," : ""
        let units = registry.ast[lang]
        let sortedUnitKeys = units.keys.sorted()
        if sortedUnitKeys.isEmpty {
          lines.append("    \"\(escape(lang.rawValue))\": {}\(langComma)")
        } else {
          lines.append("    \"\(escape(lang.rawValue))\": {")
          for (unitIdx, unitKey) in sortedUnitKeys.enumerated() {
            guard let config = units[unitKey], let configJSON = config.toCanonicalJSON() else { continue }
            let unitComma = (unitIdx < sortedUnitKeys.count - 1) ? "," : ""
            lines.append("      \"\(escape(unitKey))\": \(configJSON)\(unitComma)")
          }
          lines.append("    }\(langComma)")
        }
      }
      lines.append("  },")
    }

    // 2. "default_branch"
    lines.append("  \"default_branch\": \"\(escape(registry.defaultBranch))\",")

    // 3. "engine"
    lines.append("  \"engine\": \"\(escape(registry.engine))\",")

    // 4. "languages" (sorted JSON array ["swift", "ts"])
    if registry.languages.isEmpty {
      lines.append("  \"languages\": [],")
    } else {
      lines.append("  \"languages\": [")
      let sortedLangs = registry.languages.map(\.rawValue).sorted()
      for (idx, lang) in sortedLangs.enumerated() {
        let comma = (idx < sortedLangs.count - 1) ? "," : ""
        lines.append("    \"\(escape(lang))\"\(comma)")
      }
      lines.append("  ],")
    }

    // 5. "rules"
    if registry.rules.isEmpty {
      lines.append("  \"rules\": {},")
    } else {
      lines.append("  \"rules\": {")
      let sortedKeys = registry.rules.keys.sorted()
      for (idx, key) in sortedKeys.enumerated() {
        guard let val = registry.rules[key] else { continue }
        let comma = (idx < sortedKeys.count - 1) ? "," : ""
        lines.append("    \"\(escape(key))\": \"\(escape(val))\"\(comma)")
      }
      lines.append("  },")
    }

    // 6. "signers_hash" (optional)
    if let signersHash = registry.signersHash, !signersHash.isEmpty {
      lines.append("  \"signers_hash\": \"\(escape(signersHash))\",")
    }

    // 7. "version"
    lines.append("  \"version\": \(registry.version)")

    lines.append("}\n")
    return lines.joined(separator: "\n")
  }

  /// Parses a `Registry` from JSON Data.
  public static func parse(data: Data) throws(RegistryError) -> Registry {
    do {
      _ = try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
      throw RegistryError.invalidCanonicalJSON(error.localizedDescription)
    }
    let decoder = JSONDecoder()
    do {
      return try decoder.decode(Registry.self, from: data)
    } catch {
      throw RegistryError.decodingFailed(error.localizedDescription)
    }
  }

  public static func escape(_ string: String) -> String {
    string
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\r", with: "\\r")
      .replacingOccurrences(of: "\t", with: "\\t")
  }
}
