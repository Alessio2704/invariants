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
  public var defaultBranch: String
  public var engine: String
  public var project: ProjectConfig?
  public var rules: [String: String]
  public var signersHash: String?
  public var version: Int

  enum CodingKeys: String, CodingKey {
    case defaultBranch = "default_branch"
    case engine
    case project
    case rules
    case signersHash = "signers_hash"
    case version
  }

  public init(
    version: Int = 1,
    engine: String = "^1.0.0",
    defaultBranch: String = "main",
    project: ProjectConfig? = nil,
    rules: [String: String] = [:],
    signersHash: String? = nil
  ) {
    self.version = version
    self.engine = engine
    self.defaultBranch = defaultBranch
    self.project = project
    self.rules = rules
    self.signersHash = signersHash
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.version = try container.decode(Int.self, forKey: .version)
    self.engine = try container.decode(String.self, forKey: .engine)
    self.defaultBranch = try container.decodeIfPresent(String.self, forKey: .defaultBranch) ?? "main"
    self.project = try container.decodeIfPresent(ProjectConfig.self, forKey: .project)
    self.rules = try container.decodeIfPresent([String: String].self, forKey: .rules) ?? [:]
    self.signersHash = try container.decodeIfPresent(String.self, forKey: .signersHash)
  }
}

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
