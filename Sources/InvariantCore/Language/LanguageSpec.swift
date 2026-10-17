public import Foundation

/// The set of target languages supported by Invariants for static analysis and rule enforcement.
public enum SupportedLanguage: String, Sendable, Codable, CaseIterable {
  case swift
  case ts
}

/// Typealias preserving target terminology across manifest models.
public typealias TargetLanguage = SupportedLanguage

/// Contract for a supported language specification, binding language identity to its compile-time configuration schema.
public protocol LanguageSpec: Sendable {
  /// The strongly-typed project configuration schema required by this language.
  associatedtype Config: Sendable, Equatable, Codable

  /// Unique canonical identifier matching `SupportedLanguage`.
  static var language: SupportedLanguage { get }
}

/// Swift language specification requiring an Apple / Clang index store.
public struct SwiftLanguage: LanguageSpec {
  public static let language = SupportedLanguage.swift
  public static let displayName = "Swift"
  public static let sourceExtensions = ["swift"]
  public static let ruleFileName = "rule.swift"

  /// Swift requires a single index store path for IndexStoreDB / symbol graph analysis.
  public struct Config: Sendable, Equatable, Codable {
    public var indexStore: String

    public init(indexStore: String) {
      self.indexStore = indexStore
    }
  }

  public static func autoDiscover(repoRoot: URL) async -> Config? {
    let fm = FileManager.default
    let candidates = [
      "build/Index.noindex/DataStore",
      "build_sim/Index.noindex/DataStore",
      ".build/out",
      ".build/debug/index/store",
    ]
    for rel in candidates {
      let url = repoRoot.appendingPathComponent(rel)
      if fm.fileExists(atPath: url.path) {
        return Config(indexStore: rel)
      }
    }
    return nil
  }
}

/// TypeScript language specification requiring one or more tsconfig.json configurations.
public struct TypeScriptLanguage: LanguageSpec {
  public static let language = SupportedLanguage.ts
  public static let displayName = "TypeScript"
  public static let sourceExtensions = ["ts", "tsx", "js", "jsx"]
  public static let ruleFileName = "rule.ts"

  /// TypeScript requires an array of relative tsconfig.json paths for compiler API / ts-morph.
  public struct Config: Sendable, Equatable, Codable {
    public var tsconfig: [String]

    public init(tsconfig: [String]) {
      self.tsconfig = tsconfig
    }
  }

  public static func autoDiscover(repoRoot: URL) async -> Config? {
    let fm = FileManager.default
    var results: [String] = []

    let rootCandidates = ["tsconfig.json", "tsconfig.base.json"]
    for cand in rootCandidates where fm.fileExists(atPath: repoRoot.appendingPathComponent(cand).path) {
      results.append(cand)
    }

    let packagesDir = repoRoot.appendingPathComponent("packages")
    if let subdirs = try? fm.contentsOfDirectory(atPath: packagesDir.path) {
      for sub in subdirs.sorted() {
        let tsconfigRel = "packages/\(sub)/tsconfig.json"
        if fm.fileExists(atPath: repoRoot.appendingPathComponent(tsconfigRel).path) {
          results.append(tsconfigRel)
        }
      }
    }

    return results.isEmpty ? nil : Config(tsconfig: results)
  }
}
