public import Foundation

/// Validates rule directory structure, required/forbidden files, and scope resolution.
public enum ManifestValidator: Sendable {
  /// Validates directory layout, target files, fixture directories, and scope.
  public static func validateStructure(
    ruleDirectory: URL,
    manifest: RuleManifest,
    repoRoot: URL? = nil,
    registry: Registry? = nil,
    isFixtureMode: Bool = false
  ) throws(ManifestError) {
    let fm = FileManager.default

    // 1. Check target files and fixture folders
    for target in TargetLanguage.allCases {
      let isDeclared = manifest.targets.contains(target)
      let ruleFileName = target.spec.ruleFileName
      let ruleFileURL = ruleDirectory.appendingPathComponent(ruleFileName)

      if isDeclared {
        guard fm.fileExists(atPath: ruleFileURL.path) else {
          throw ManifestError.missingRuleFile(target, ruleFileName)
        }

        // Check should_pass and should_fail folders
        let passURL = ruleDirectory.appendingPathComponent("should_pass/\(target.rawValue)")
        guard fm.fileExists(atPath: passURL.path) else {
          throw ManifestError.missingFixtureFolder("should_pass/\(target.rawValue)")
        }
        let passCases = (try? fm.contentsOfDirectory(atPath: passURL.path))?.filter { !$0.hasPrefix(".") } ?? []
        guard !passCases.isEmpty else {
          throw ManifestError.emptyFixtureFolder("should_pass/\(target.rawValue)")
        }

        let failURL = ruleDirectory.appendingPathComponent("should_fail/\(target.rawValue)")
        guard fm.fileExists(atPath: failURL.path) else {
          throw ManifestError.missingFixtureFolder("should_fail/\(target.rawValue)")
        }
        let failCases = (try? fm.contentsOfDirectory(atPath: failURL.path))?.filter { !$0.hasPrefix(".") } ?? []
        guard !failCases.isEmpty else {
          throw ManifestError.emptyFixtureFolder("should_fail/\(target.rawValue)")
        }

        // In repo mode: verify target is configured in registry.languages
        if !isFixtureMode, let registry {
          guard registry.languages.isConfigured(target) else {
            throw ManifestError.missingTargetInRegistryLanguages(target)
          }
        }
      } else {
        // Not declared: rule file MUST NOT exist
        if fm.fileExists(atPath: ruleFileURL.path) {
          throw ManifestError.forbiddenRuleFile(target, ruleFileName)
        }
      }
    }

    // 2. In repo mode, verify each declared scope matches >= 1 real file
    if !isFixtureMode, let repoRoot {
      for target in manifest.targets {
        guard let targetScope = manifest.scope[target] else {
          throw ManifestError.missingTargetScope(target)
        }
        let matchingFiles = resolveScopedFiles(repoRoot: repoRoot, scope: targetScope)
        if matchingFiles.isEmpty {
          throw ManifestError.scopeMatchesNoFiles(target, targetScope.include)
        }
      }
    }
  }

  /// Resolves all files in repoRoot matching the include patterns and not excluded.
  public static func resolveScopedFiles(repoRoot: URL, scope: TargetScope) -> [URL] {
    let fm = FileManager.default
    guard
      let enumerator = fm.enumerator(
        at: repoRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else {
      return []
    }

    let includeMatchers = scope.include.compactMap { GlobMatcher(pattern: $0) }
    let excludeMatchers = (scope.exclude ?? []).compactMap { GlobMatcher(pattern: $0) }

    var results: [URL] = []
    let repoPath = repoRoot.standardizedFileURL.path

    for case let fileURL as URL in enumerator {
      guard let isRegularFile = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
        isRegularFile
      else {
        continue
      }

      let standardFilePath = fileURL.standardizedFileURL.path
      guard standardFilePath.hasPrefix(repoPath) else { continue }
      var relPath = String(standardFilePath.dropFirst(repoPath.count))
      if relPath.hasPrefix("/") {
        relPath = String(relPath.dropFirst())
      }

      // Exclude git and .build directories
      if relPath.hasPrefix(".git/") || relPath.hasPrefix(".build/") || relPath.hasPrefix("node_modules/") {
        continue
      }

      // Check include match
      let matchesInclude = includeMatchers.contains { $0.matches(relPath) }
      guard matchesInclude else { continue }

      // Check exclude match
      let matchesExclude = excludeMatchers.contains { $0.matches(relPath) }
      guard !matchesExclude else { continue }

      results.append(fileURL)
    }

    return results.sorted { $0.path < $1.path }
  }

  /// Validates that all codes declared in the manifest are covered by at least one fixture.
  public static func validateCodesCoverage(
    manifest: RuleManifest,
    coveredCodes: Set<String>
  ) throws(ManifestError) {
    for code in manifest.codes.keys.sorted() where !coveredCodes.contains(code) {
      throw ManifestError.codeNotTestedByFixtures(code)
    }
  }

  /// Validates that all violations emitted by a rule correspond to codes declared in the manifest.
  public static func validateReportedViolations(
    manifest: RuleManifest,
    violations: [ReportedViolation]
  ) throws(ManifestError) {
    for violation in violations where manifest.codes[violation.code] == nil {
      throw ManifestError.undeclaredCodeEmitted(code: violation.code, ruleId: manifest.id)
    }
  }
}
