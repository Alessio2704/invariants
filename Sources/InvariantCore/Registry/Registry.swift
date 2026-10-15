public import Foundation

/// Project-wide analysis inputs declared in registry.lock.
public struct SwiftProjectConfig: Sendable, Equatable, Codable {
  public var indexStore: String

  public init(indexStore: String) {
    self.indexStore = indexStore
  }
}

public struct TSProjectConfig: Sendable, Equatable, Codable {
  public var tsconfig: [String]

  public init(tsconfig: [String]) {
    self.tsconfig = tsconfig
  }
}

public struct ProjectConfig: Sendable, Equatable, Codable {
  public var swift: SwiftProjectConfig?
  public var ts: TSProjectConfig?

  public init(swift: SwiftProjectConfig? = nil, ts: TSProjectConfig? = nil) {
    self.swift = swift
    self.ts = ts
  }

  public var isEmpty: Bool {
    swift == nil && ts == nil
  }
}

/// The root model for `invariants/registry.lock`.
public struct Registry: Sendable, Equatable, Codable {
  public var engine: String
  public var project: ProjectConfig?
  public var repo: String
  public var rules: [String: String]
  public var version: Int

  public init(
    repo: String,
    version: Int = 1,
    engine: String = "^1.0.0",
    project: ProjectConfig? = nil,
    rules: [String: String] = [:]
  ) {
    self.repo = repo
    self.version = version
    self.engine = engine
    self.project = project
    self.rules = rules
  }
}

/// Canonical JSON formatting and parsing for `Registry`.
public enum CanonicalJSON {
  /// Serializes a `Registry` into deterministic canonical JSON format.
  public static func serialize(_ registry: Registry) -> String {
    var lines: [String] = ["{"]

    // 1. "engine"
    lines.append("  \"engine\": \"\(escape(registry.engine))\",")

    // 2. "project" (optional)
    if let project = registry.project, !project.isEmpty {
      lines.append("  \"project\": {")
      var projEntries: [String] = []

      if let swift = project.swift {
        projEntries.append("    \"swift\": { \"indexStore\": \"\(escape(swift.indexStore))\" }")
      }
      if let ts = project.ts {
        let formattedTsconfigs = ts.tsconfig.map { "\"\(escape($0))\"" }.joined(separator: ", ")
        projEntries.append("    \"ts\": { \"tsconfig\": [\(formattedTsconfigs)] }")
      }
      for i in 0..<projEntries.count {
        let entry = projEntries[i]
        let comma = (i < projEntries.count - 1) ? "," : ""
        lines.append(entry + comma)
      }
      lines.append("  },")
    }

    // 3. "repo"
    lines.append("  \"repo\": \"\(escape(registry.repo))\",")

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

    // 5. "version"
    lines.append("  \"version\": \(registry.version)")

    lines.append("}\n")
    return lines.joined(separator: "\n")
  }

  /// Parses a `Registry` from JSON Data.
  public static func parse(data: Data) throws(RegistryError) -> Registry {
    let decoder = JSONDecoder()
    do {
      return try decoder.decode(Registry.self, from: data)
    } catch {
      throw RegistryError.decodingFailed(error.localizedDescription)
    }
  }

  private static func escape(_ string: String) -> String {
    string
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\r", with: "\\r")
      .replacingOccurrences(of: "\t", with: "\\t")
  }
}
