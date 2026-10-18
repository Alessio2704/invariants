import ArgumentParser
import Foundation
import InvariantCore

struct TestCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "test",
    abstract: "Execute fixtures for a rule from the working tree."
  )

  @Argument(help: "The rule ID to test.")
  var id: String

  func run() async throws {
    let repoRootURL = try CLIHelpers.requireRepoRoot()

    let ruleDir = repoRootURL.appendingPathComponent("invariants/rules/\(id)")
    let fm = FileManager.default

    guard fm.fileExists(atPath: ruleDir.path) else {
      fputs("Error: Rule '\(id)' not found at \(ruleDir.path)\n", stderr)
      throw ExitCode(1)
    }

    let manifestURL = ruleDir.appendingPathComponent("manifest.json")
    let manifest: RuleManifest
    do {
      manifest = try ManifestParser.load(from: manifestURL, expectedId: id)
      try ManifestValidator.validateStructure(
        ruleDirectory: ruleDir,
        manifest: manifest,
        repoRoot: repoRootURL,
        registry: nil,
        isFixtureMode: true
      )
    } catch {
      fputs("Error: Manifest validation failed: \(error)\n", stderr)
      throw ExitCode(1)
    }

    print("Testing invariant fixtures: \(id)")
    print("────────────────────────────────")

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
        fputs("Error discovering fixtures for \(target.rawValue): \(error)\n", stderr)
        throw ExitCode(1)
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
          files: fixtureCase.files.map { $0.path }
        )

        let reportedViolations: [ReportedViolation]
        do {
          reportedViolations = try await runner.execute(
            target: target,
            ruleDirectory: ruleDir,
            ruleTreeHash: "working_tree",
            request: req,
            engineVersion: CLIHelpers.engineVersion
          )
        } catch let runnerErr {
          let harnessErr: HarnessError
          switch runnerErr {
          case .ruleCrashed(_, let stderr):
            harnessErr = .ruleCrashed(caseId: fixtureCase.id, message: stderr)
          case .ruleHung:
            harnessErr = .ruleHung(caseId: fixtureCase.id)
          default:
            print("  ✗ \(caseLabel): execution failed: \(runnerErr)")
            hasFailures = true
            continue
          }
          print("  ✗ \(caseLabel): \(harnessErr.description)")
          hasFailures = true
          continue
        }

        if let error = fixtureCase.evaluateExpectations(reportedViolations: reportedViolations) {
          print("  ✗ \(caseLabel): \(error.description)")
          hasFailures = true
        } else {
          do {
            try ManifestValidator.validateReportedViolations(manifest: manifest, violations: reportedViolations)
            if fixtureCase.isShouldPass {
              print("  ✓ \(caseLabel): 0 violations (pass)")
            } else {
              print("  ✓ \(caseLabel): matched all \(fixtureCase.expectedViolations.count) expected violations")
            }
            passedCases += 1
          } catch {
            print("  ✗ \(caseLabel): \(error)")
            hasFailures = true
          }
        }
      }

      do {
        try ManifestValidator.validateCodesCoverage(manifest: manifest, coveredCodes: coveredCodes)
      } catch {
        print("  ✗ \(target.rawValue): \(error)")
        hasFailures = true
      }
    }

    print("\nSummary: \(passedCases)/\(totalCases) fixture cases passed")
    if hasFailures {
      throw ExitCode(1)
    }
  }
}
