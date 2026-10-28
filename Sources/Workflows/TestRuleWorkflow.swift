import Core
import Foundation
import Terminal

/// Interactive CLI workflow to execute and verify test fixtures for a rule.
package enum TestRuleWorkflow {
  /// Executes fixtures for the specified rule ID, reports results to the terminal, and returns whether all fixtures passed.
  package static func execute(ruleId: String) async throws -> Bool {
    let ruleDir = RepoLocator.current.appendingPathComponent("invariants/rules/\(ruleId)")
    let fm = FileManager.default

    guard fm.fileExists(atPath: ruleDir.path) else {
      Terminal.error("Rule '\(ruleId)' not found at \(ruleDir.path)")
      return false
    }

    let registry: Registry
    do {
      registry = try await RegistryManager.loadAndVerify()
    } catch {
      Terminal.error("Registry verification failed: \(error)")
      return false
    }

    let manifestURL = ruleDir.appendingPathComponent("manifest.json")
    let manifest: RuleManifest
    do {
      manifest = try ManifestParser.load(from: manifestURL, expectedId: ruleId)
      try ManifestValidator.validateStructure(
        ruleDirectory: ruleDir,
        manifest: manifest,
        registry: registry,
        isFixtureMode: true
      )
    } catch {
      Terminal.error("Manifest validation failed: \(error)")
      return false
    }

    Terminal.header("Testing invariant fixtures: \(ruleId)")

    let runner = RuleRunner()
    var hasFailures = false
    var totalCases = 0
    var passedCases = 0
    let ruleTreeHash = (try? await FingerprintEngine.computeFingerprint(ruleId: ruleId)) ?? "rule_\(ruleId)"
    let fixtureContext = FixtureContext(
      manifest: manifest,
      ruleDirectory: ruleDir,
      ruleTreeHash: ruleTreeHash,
      languages: registry.languages
    )

    for target in manifest.targets {
      let results: [FixtureCaseExecutionResult]
      do {
        results = try await FixtureExecutionService.evaluateTargetFixtures(
          target: target,
          context: fixtureContext,
          runner: runner
        )
      } catch {
        Terminal.error("Error discovering fixtures for \(target.rawValue): \(error)")
        return false
      }

      var coveredCodes: Set<String> = []

      for res in results {
        if !res.fixtureCase.isShouldPass {
          for exp in res.fixtureCase.expectedViolations {
            coveredCodes.insert(exp.code)
          }
        }
        totalCases += 1
        let caseLabel =
          "\(res.fixtureCase.isShouldPass ? "should_pass" : "should_fail")/\(target.rawValue)/\(res.fixtureCase.id)"

        if res.isPassed {
          let detail =
            res.fixtureCase.isShouldPass
            ? "0 violations (pass)"
            : "matched all \(res.fixtureCase.expectedViolations.count) expected violations"
          Terminal.statusItem("✓", label: caseLabel, detail: detail)
          passedCases += 1
        } else {
          Terminal.statusItem("✗", label: caseLabel, detail: res.errorDescription ?? "Failed")
          hasFailures = true
        }
      }

      do {
        try ManifestValidator.validateCodesCoverage(manifest: manifest, coveredCodes: coveredCodes)
      } catch {
        Terminal.statusItem("✗", label: target.rawValue, detail: "\(error)")
        hasFailures = true
      }
    }

    Terminal.line("\nSummary: \(passedCases)/\(totalCases) fixture cases passed")
    return !hasFailures
  }
}
