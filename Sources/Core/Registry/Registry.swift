import Foundation

/// The root model for `invariants/registry.lock`.
public struct Registry: Sendable, Equatable, Codable {
  public var defaultBranch: String
  public var engine: String
  public var languages: LanguagesConfig
  public var rules: [String: String]
  public var signersHash: String?
  public var version: Int

  enum CodingKeys: String, CodingKey {
    case defaultBranch = "default_branch"
    case engine
    case languages
    case rules
    case signersHash = "signers_hash"
    case version
  }

  public init(
    version: Int = 1,
    engine: String = "^1.0.0",
    defaultBranch: String = "main",
    languages: LanguagesConfig,
    rules: [String: String] = [:],
    signersHash: String? = nil
  ) {
    self.version = version
    self.engine = engine
    self.defaultBranch = defaultBranch
    self.languages = languages
    self.rules = rules
    self.signersHash = signersHash
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.version = try container.decode(Int.self, forKey: .version)
    self.engine = try container.decode(String.self, forKey: .engine)
    self.defaultBranch = try container.decodeIfPresent(String.self, forKey: .defaultBranch) ?? "main"
    self.languages = try container.decode(LanguagesConfig.self, forKey: .languages)
    self.rules = try container.decodeIfPresent([String: String].self, forKey: .rules) ?? [:]
    self.signersHash = try container.decodeIfPresent(String.self, forKey: .signersHash)
  }
}
