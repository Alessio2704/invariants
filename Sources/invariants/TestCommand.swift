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
    let manifestData: Data
    do {
      manifestData = try Data(contentsOf: manifestURL)
    } catch {
      fputs("Error: manifest.json missing for rule '\(id)'\n", stderr)
      throw ExitCode(1)
    }

    let manifest: RuleManifest
    do {
      manifest = try ManifestParser.parse(data: manifestData, expectedId: id)
      let validator = ManifestValidator()
      try validator.validateStructure(
        ruleDirectory: ruleDir,
        manifest: manifest,
        repoRoot: repoRootURL,
        registry: nil,
        isFixtureMode: true
      )
    } catch {
      fputs("Error: Structural validation failed: \(error)\n", stderr)
      throw ExitCode(1)
    }

    print("Testing invariant fixtures: \(id)")
    print("────────────────────────────────")

    let discoverer = FixtureDiscoverer()
    let runner = RuleRunner()
    var hasFailures = false
    var totalCases = 0
    var passedCases = 0

    for target in manifest.targets {
      let cases: [FixtureCase]
      do {
        cases = try discoverer.discover(
          ruleDirectory: ruleDir,
          target: target,
          manifestCodes: manifest.codes
        )
      } catch {
        fputs("Error discovering fixtures for \(target.rawValue): \(error)\n", stderr)
        throw ExitCode(1)
      }

      for fixtureCase in cases {
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
        } catch {
          print("  ✗ \(caseLabel): execution failed: \(error)")
          hasFailures = true
          continue
        }

        if fixtureCase.isShouldPass {
          if reportedViolations.isEmpty {
            print("  ✓ \(caseLabel): 0 violations (pass)")
            passedCases += 1
          } else {
            print("  ✗ \(caseLabel): expected 0 violations, got \(reportedViolations.count):")
            for v in reportedViolations {
              print("      \(v.code) \(v.file):\(v.line): \(v.message)")
            }
            hasFailures = true
          }
        } else {
          let expectedSet = Set(fixtureCase.expectedViolations)
          let reportedSet = Set(
            reportedViolations.map {
              ExpectedViolation(
                relativePath: URL(fileURLWithPath: $0.file).lastPathComponent,
                line: $0.line,
                code: $0.code
              )
            })

          if expectedSet == reportedSet {
            print("  ✓ \(caseLabel): matched all \(expectedSet.count) expected violations")
            passedCases += 1
          } else {
            let missing = expectedSet.subtracting(reportedSet)
            let unexpected = reportedSet.subtracting(expectedSet)
            print("  ✗ \(caseLabel): expectation mismatch")
            for m in missing {
              print("      [MISSING] expected \(m.code) at \(m.relativePath):\(m.line)")
            }
            for u in unexpected {
              print("      [UNEXPECTED] reported \(u.code) at \(u.relativePath):\(u.line)")
            }
            hasFailures = true
          }
        }
      }
    }

    print("\nSummary: \(passedCases)/\(totalCases) fixture cases passed")
    if hasFailures {
      throw ExitCode(1)
    }
  }
}
