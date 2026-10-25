import Foundation

/// Thread-safe in-memory cache for fixture results.
public actor FixtureCache {
  public static let shared = FixtureCache()

  private var passedHashes: Set<String> = []

  public init() {}

  private func cacheKey(ruleTreeHash: String) -> String {
    "\(EngineVersion.current):\(ruleTreeHash)"
  }

  public func isCachedPass(ruleTreeHash: String) -> Bool {
    passedHashes.contains(cacheKey(ruleTreeHash: ruleTreeHash))
  }

  public func recordPass(ruleTreeHash: String) {
    passedHashes.insert(cacheKey(ruleTreeHash: ruleTreeHash))
  }
}
