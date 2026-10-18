public import Foundation

/// Canonical JSON formatting and parsing for `Registry`.
public enum CanonicalJSON {
  /// Serializes a `Registry` into deterministic canonical JSON format.
  public static func serialize(_ registry: Registry) -> String {
    var lines: [String] = ["{"]

    // 1. "default_branch"
    lines.append("  \"default_branch\": \"\(escape(registry.defaultBranch))\",")

    // 2. "engine"
    lines.append("  \"engine\": \"\(escape(registry.engine))\",")

    // 3. "project" (optional)
    if let project = registry.project, !project.isEmpty {
      lines.append("  \"project\": {")
      let languages = project.configuredLanguages
      for (idx, lang) in languages.enumerated() {
        guard let jsonString = project.canonicalJSON(for: lang) else { continue }
        let comma = (idx < languages.count - 1) ? "," : ""
        lines.append("    \"\(escape(lang.rawValue))\": \(jsonString)\(comma)")
      }
      lines.append("  },")
    }

    // 4. "rules"
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

    // 5. "signers_hash" (optional)
    if let signersHash = registry.signersHash, !signersHash.isEmpty {
      lines.append("  \"signers_hash\": \"\(escape(signersHash))\",")
    }

    // 6. "version"
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
