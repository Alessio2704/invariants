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
      registry = try await RegistryManager.loadAndVerify(
        installedEngineVersion: EngineVersion.current
      )
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

    for target in manifest.targets {
      let cases: [FixtureCase]
      do {
        cases = try FixtureDiscoverer.discover(
          ruleDirectory: ruleDir,
          target: target,
          manifestCodes: manifest.codes
        )
      } catch {
        Terminal.error("Error discovering fixtures for \(target.rawValue): \(error)")
        return false
      }

      var coveredCodes: Set<String> = []

      for fixtureCase in cases {
        if !fixtureCase.isShouldPass {
          for exp in fixtureCase.expectedViolations {
            coveredCodes.insert(exp.code)
          }
        }
        totalCases += 1
        let caseLabel =
          "\(fixtureCase.isShouldPass ? "should_pass" : "should_fail")/\(target.rawValue)/\(fixtureCase.id)"

        let req = RuleRequest(
          mode: "fixture",
          repoRoot: fixtureCase.rootURL.path,
          ruleDir: ruleDir.path,
          files: fixtureCase.files.map { $0.path },
          languages: registry.languages
        )

        let reportedViolations: [ReportedViolation]
        do {
          reportedViolations = try await runner.execute(
            target: target,
            ruleDirectory: ruleDir,
            ruleTreeHash: "working_tree",
            request: req,
            engineVersion: EngineVersion.current
          )
        } catch let runnerErr {
          let harnessErr: HarnessError
          switch runnerErr {
          case .ruleCrashed(_, let stderr):
            harnessErr = .ruleCrashed(caseId: fixtureCase.id, message: stderr)
          case .ruleHung:
            harnessErr = .ruleHung(caseId: fixtureCase.id)
          default:
            Terminal.statusItem("✗", label: caseLabel, detail: "execution failed: \(runnerErr)")
            hasFailures = true
            continue
          }
          Terminal.statusItem("✗", label: caseLabel, detail: harnessErr.description)
          hasFailures = true
          continue
        }

        if let error = fixtureCase.evaluateExpectations(reportedViolations: reportedViolations) {
          Terminal.statusItem("✗", label: caseLabel, detail: error.description)
          hasFailures = true
        } else {
          do {
            try ManifestValidator.validateReportedViolations(manifest: manifest, violations: reportedViolations)
            if fixtureCase.isShouldPass {
              Terminal.statusItem("✓", label: caseLabel, detail: "0 violations (pass)")
            } else {
              Terminal.statusItem(
                "✓", label: caseLabel,
                detail: "matched all \(fixtureCase.expectedViolations.count) expected violations")
            }
            passedCases += 1
          } catch {
            Terminal.statusItem("✗", label: caseLabel, detail: "\(error)")
            hasFailures = true
          }
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
