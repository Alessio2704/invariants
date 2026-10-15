import Foundation

/// Thread-safe in-memory cache for fixture results.
public actor FixtureCache {
  public static let shared = FixtureCache()

  private var passedHashes: Set<String> = []

  public init() {}

  private func cacheKey(engineVersion: String, ruleTreeHash: String) -> String {
    "\(engineVersion):\(ruleTreeHash)"
  }

  public func isCachedPass(engineVersion: String, ruleTreeHash: String) -> Bool {
    passedHashes.contains(cacheKey(engineVersion: engineVersion, ruleTreeHash: ruleTreeHash))
  }

  public func recordPass(engineVersion: String, ruleTreeHash: String) {
    passedHashes.insert(cacheKey(engineVersion: engineVersion, ruleTreeHash: ruleTreeHash))
  }

  public func clear() {
    passedHashes.removeAll()
  }
}
