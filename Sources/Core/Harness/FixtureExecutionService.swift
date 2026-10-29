public import Foundation

public struct FixtureContext: Sendable {
  public let manifest: RuleManifest
  public let ruleDirectory: URL
  public let ruleTreeHash: String
  public let ast: ASTConfig

  public init(
    manifest: RuleManifest,
    ruleDirectory: URL,
    ruleTreeHash: String,
    ast: ASTConfig = ASTConfig()
  ) {
    self.manifest = manifest
    self.ruleDirectory = ruleDirectory
    self.ruleTreeHash = ruleTreeHash
    self.ast = ast
  }
}

public struct FixtureExecutionOutcome: Sendable {
  public let totalCases: Int
  public let passedCases: Int
  public let failures: [FixtureFailure]

  public var isAllPassed: Bool {
    failures.isEmpty && totalCases > 0
  }

  public init(totalCases: Int, passedCases: Int, failures: [FixtureFailure]) {
    self.totalCases = totalCases
    self.passedCases = passedCases
    self.failures = failures
  }
}

public struct FixtureFailure: Sendable {
  public let caseId: String
  public let target: TargetLanguage
  public let isShouldPass: Bool
  public let message: String

  public init(caseId: String, target: TargetLanguage, isShouldPass: Bool, message: String) {
    self.caseId = caseId
    self.target = target
    self.isShouldPass = isShouldPass
    self.message = message
  }
}

public struct FixtureCaseExecutionResult: Sendable {
  public let fixtureCase: FixtureCase
  public let target: TargetLanguage
  public let violations: [ReportedViolation]
  public let errorDescription: String?

  public var isPassed: Bool { errorDescription == nil }

  public init(
    fixtureCase: FixtureCase,
    target: TargetLanguage,
    violations: [ReportedViolation],
    errorDescription: String?
  ) {
    self.fixtureCase = fixtureCase
    self.target = target
    self.violations = violations
    self.errorDescription = errorDescription
  }
}

/// Centralized service to execute and validate invariant rule test fixtures.
public enum FixtureExecutionService {
  /// Evaluates all fixtures across all targets for a rule.
  /// Throws `HarnessError` if any fixture fails to meet expectations or manifests violation errors.
  public static func verifyAllFixtures(
    manifest: RuleManifest,
    ruleDirectory: URL,
    ruleTreeHash: String,
    ast: ASTConfig = ASTConfig(),
    runner: RuleRunner
  ) async throws(HarnessError) {
    let outcome = try await evaluateFixtures(
      manifest: manifest,
      ruleDirectory: ruleDirectory,
      ruleTreeHash: ruleTreeHash,
      ast: ast,
      runner: runner
    )
    if !outcome.isAllPassed {
      if let firstFailure = outcome.failures.first {
        throw HarnessError.expectationMismatch(
          caseId: firstFailure.caseId,
          message: firstFailure.message
        )
      } else {
        throw HarnessError.manifestError("No fixtures passed verification.")
      }
    }
  }

  /// Evaluates fixtures for a specific target language and returns individual case results.
  public static func evaluateTargetFixtures(
    target: TargetLanguage,
    context: FixtureContext,
    runner: RuleRunner
  ) async throws(HarnessError) -> [FixtureCaseExecutionResult] {
    let cases: [FixtureCase]
    do {
      cases = try FixtureDiscoverer.discover(
        ruleDirectory: context.ruleDirectory,
        target: target,
        manifestCodes: context.manifest.codes
      )
    } catch {
      throw HarnessError.manifestError("Failed to discover fixtures for \(target): \(error)")
    }

    var results: [FixtureCaseExecutionResult] = []
    for fixtureCase in cases {
      let declaredUnits = context.manifest.scope[target]?.keys.sorted() ?? []
      var unitFiles: [String: [String]] = [:]

      var matchedSubdir = false
      for unit in declaredUnits {
        let unitSubdir = fixtureCase.rootURL.appendingPathComponent(unit).standardizedFileURL.path
        let matching = fixtureCase.files
          .filter {
            let p = $0.standardizedFileURL.path
            return p.hasPrefix(unitSubdir + "/") || p == unitSubdir
          }
          .map(\.path)
        if !matching.isEmpty {
          unitFiles[unit] = matching
          matchedSubdir = true
        } else {
          unitFiles[unit] = []
        }
      }

      if !matchedSubdir {
        let allPaths = fixtureCase.files.map(\.path)
        for unit in declaredUnits {
          unitFiles[unit] = allPaths
        }
      }

      let req = RuleRequest(
        mode: "fixture",
        repoRoot: fixtureCase.rootURL.path,
        ruleDir: context.ruleDirectory.path,
        files: fixtureCase.files.map(\.path),
        unitFiles: unitFiles,
        ast: context.ast
      )

      let violations: [ReportedViolation]
      do {
        violations = try await runner.execute(
          target: target,
          ruleDirectory: context.ruleDirectory,
          ruleTreeHash: context.ruleTreeHash,
          request: req
        )
      } catch let runnerErr {
        let failureMsg: String
        switch runnerErr {
        case .ruleCrashed(_, let stderr):
          failureMsg = HarnessError.ruleCrashed(caseId: fixtureCase.id, message: stderr).description
        case .ruleHung:
          failureMsg = HarnessError.ruleHung(caseId: fixtureCase.id).description
        default:
          failureMsg = "Runner execution error: \(runnerErr)"
        }
        results.append(
          FixtureCaseExecutionResult(
            fixtureCase: fixtureCase,
            target: target,
            violations: [],
            errorDescription: failureMsg
          ))
        continue
      }

      if let error = fixtureCase.evaluateExpectations(reportedViolations: violations) {
        results.append(
          FixtureCaseExecutionResult(
            fixtureCase: fixtureCase,
            target: target,
            violations: violations,
            errorDescription: error.description
          ))
        continue
      }

      do {
        try ManifestValidator.validateReportedViolations(manifest: context.manifest, violations: violations)
        results.append(
          FixtureCaseExecutionResult(
            fixtureCase: fixtureCase,
            target: target,
            violations: violations,
            errorDescription: nil
          ))
      } catch {
        results.append(
          FixtureCaseExecutionResult(
            fixtureCase: fixtureCase,
            target: target,
            violations: violations,
            errorDescription: error.localizedDescription
          ))
      }
    }
    return results
  }

  /// Evaluates all fixtures across all targets and returns a detailed execution outcome.
  public static func evaluateFixtures(
    manifest: RuleManifest,
    ruleDirectory: URL,
    ruleTreeHash: String,
    ast: ASTConfig = ASTConfig(),
    runner: RuleRunner
  ) async throws(HarnessError) -> FixtureExecutionOutcome {
    let context = FixtureContext(
      manifest: manifest,
      ruleDirectory: ruleDirectory,
      ruleTreeHash: ruleTreeHash,
      ast: ast
    )
    return try await evaluateFixtures(context: context, runner: runner)
  }

  /// Evaluates all fixtures across all targets given a `FixtureContext`.
  public static func evaluateFixtures(
    context: FixtureContext,
    runner: RuleRunner
  ) async throws(HarnessError) -> FixtureExecutionOutcome {
    var totalCases = 0
    var passedCases = 0
    var failures: [FixtureFailure] = []

    for target in context.manifest.targets {
      let results = try await evaluateTargetFixtures(
        target: target,
        context: context,
        runner: runner
      )

      for res in results {
        totalCases += 1
        if let err = res.errorDescription {
          failures.append(
            FixtureFailure(
              caseId: res.fixtureCase.id,
              target: target,
              isShouldPass: res.fixtureCase.isShouldPass,
              message: err
            ))
        } else {
          passedCases += 1
        }
      }
    }

    return FixtureExecutionOutcome(
      totalCases: totalCases,
      passedCases: passedCases,
      failures: failures
    )
  }
}
