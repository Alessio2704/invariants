public import Foundation

/// Strict JSON parser for `manifest.json` ensuring no unknown keys and exact types.
public enum ManifestParser {
  /// Loads and parses a `manifest.json` file from a URL.
  public static func load(from url: URL, expectedId: String? = nil) throws(ManifestError) -> RuleManifest {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw ManifestError.fileNotFound(url)
    }
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw ManifestError.fileNotFound(url)
    }
    return try parse(data: data, expectedId: expectedId)
  }

  public static func parse(data: Data, expectedId: String? = nil) throws(ManifestError) -> RuleManifest {
    let jsonObject: Any
    do {
      jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
      throw ManifestError.invalidJSON(error.localizedDescription)
    }

    guard let dict = jsonObject as? [String: Any] else {
      throw ManifestError.invalidJSON("Top-level JSON must be an object")
    }

    let allowedTopLevelKeys: Set<String> = ["id", "summary", "targets", "scope", "codes"]
    for key in dict.keys where !allowedTopLevelKeys.contains(key) {
      throw ManifestError.unknownKey(key)
    }

    // 1. id
    guard let id = dict["id"] as? String, !id.isEmpty else {
      throw ManifestError.missingField("id")
    }
    if let expectedId, id != expectedId {
      throw ManifestError.idMismatch(expected: expectedId, found: id)
    }

    // 2. summary
    guard let summary = dict["summary"] as? String, !summary.isEmpty else {
      throw ManifestError.missingField("summary")
    }

    // 3. targets
    guard let rawTargets = dict["targets"] as? [String] else {
      throw ManifestError.missingField("targets")
    }
    guard !rawTargets.isEmpty else {
      throw ManifestError.emptyTargets
    }

    var targets: [TargetLanguage] = []
    for raw in rawTargets {
      guard let target = TargetLanguage(rawValue: raw) else {
        throw ManifestError.invalidTarget(raw)
      }
      targets.append(target)
    }

    // 4. scope
    guard let scopeDict = dict["scope"] as? [String: Any] else {
      throw ManifestError.missingField("scope")
    }

    var scope: [TargetLanguage: TargetScope] = [:]
    for target in targets {
      guard let targetScopeObj = scopeDict[target.rawValue] as? [String: Any] else {
        throw ManifestError.missingTargetScope(target)
      }

      let allowedScopeKeys: Set<String> = ["include", "exclude"]
      for key in targetScopeObj.keys where !allowedScopeKeys.contains(key) {
        throw ManifestError.unknownKey("scope.\(target.rawValue).\(key)")
      }

      guard let include = targetScopeObj["include"] as? [String], !include.isEmpty else {
        throw ManifestError.emptyScopeInclude(target)
      }

      let exclude = targetScopeObj["exclude"] as? [String]
      scope[target] = TargetScope(include: include, exclude: exclude)
    }

    // Check for undeclared targets in scope object
    for key in scopeDict.keys where !targets.contains(where: { $0.rawValue == key }) {
      throw ManifestError.unknownKey("scope.\(key)")
    }

    // 5. codes
    guard let codesDict = dict["codes"] as? [String: String], !codesDict.isEmpty else {
      throw ManifestError.emptyCodes
    }

    return RuleManifest(
      id: id,
      summary: summary,
      targets: targets,
      scope: scope,
      codes: codesDict
    )
  }
}
