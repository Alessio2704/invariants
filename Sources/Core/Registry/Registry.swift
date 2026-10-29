import Foundation

/// The root model for `invariants/registry.lock`.
public struct Registry: Sendable, Equatable, Codable {
  public var defaultBranch: String
  public var engine: String
  public var languages: [SupportedLanguage] {
    didSet {
      languages = Array(Set(languages)).sorted(by: { $0.rawValue < $1.rawValue })
    }
  }
  public var ast: ASTConfig
  public var rules: [String: String]
  public var signersHash: String?
  public var version: Int

  enum CodingKeys: String, CodingKey {
    case ast
    case defaultBranch = "default_branch"
    case engine
    case languages
    case rules
    case signersHash = "signers_hash"
    case version
  }

  public init(
    version: Int = 1,
    engine: String = EngineVersion.defaultRange,
    defaultBranch: String = "main",
    languages: [SupportedLanguage],
    ast: ASTConfig = ASTConfig(),
    rules: [String: String] = [:],
    signersHash: String? = nil
  ) {
    self.version = version
    self.engine = engine
    self.defaultBranch = defaultBranch
    self.languages = Array(Set(languages)).sorted(by: { $0.rawValue < $1.rawValue })
    self.ast = ast
    self.rules = rules
    self.signersHash = signersHash
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.version = try container.decode(Int.self, forKey: .version)
    self.engine = try container.decode(String.self, forKey: .engine)
    self.defaultBranch = try container.decodeIfPresent(String.self, forKey: .defaultBranch) ?? "main"
    self.languages = try container.decode([SupportedLanguage].self, forKey: .languages)
    self.ast = try container.decodeIfPresent(ASTConfig.self, forKey: .ast) ?? ASTConfig()
    self.rules = try container.decodeIfPresent([String: String].self, forKey: .rules) ?? [:]
    self.signersHash = try container.decodeIfPresent(String.self, forKey: .signersHash)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(ast, forKey: .ast)
    try container.encode(defaultBranch, forKey: .defaultBranch)
    try container.encode(engine, forKey: .engine)
    try container.encode(languages, forKey: .languages)
    try container.encode(rules, forKey: .rules)
    try container.encodeIfPresent(signersHash, forKey: .signersHash)
    try container.encode(version, forKey: .version)
  }
}
