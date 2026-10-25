public import Foundation

/// Builds and executes rule processes across supported languages according to their declarative execution specs.
public struct RuleRunner: Sendable {
  public let environment: SystemEnvironment
  public var timeoutSeconds: Double

  public init(
    environment: SystemEnvironment = .standard,
    timeoutSeconds: Double = SubprocessRunner.defaultTimeoutSeconds
  ) {
    self.environment = environment
    self.timeoutSeconds = timeoutSeconds
  }

  /// Executes a rule for a given target language and returns parsed violations based on its declarative execution spec.
  public func execute(
    target: TargetLanguage,
    ruleDirectory: URL,
    ruleTreeHash: String,
    request: RuleRequest
  ) async throws(RuleRunnerError) -> [ReportedViolation] {
    let spec = target.spec.executionSpec
    switch spec.model {
    case .compiled:
      return try await executeCompiledRule(
        spec: spec,
        ruleDirectory: ruleDirectory,
        ruleTreeHash: ruleTreeHash,
        request: request
      )
    case .interpreted(let interpreted):
      return try await executeInterpretedRule(
        target: target,
        spec: interpreted,
        reporting: spec.reporting,
        ruleDirectory: ruleDirectory,
        request: request
      )
    }
  }

  func parseViolations(from data: Data) throws(RuleRunnerError) -> [ReportedViolation] {
    let decoder = JSONDecoder()
    do {
      return try decoder.decode([ReportedViolation].self, from: data)
    } catch {
      let text = String(bytes: data, encoding: .utf8) ?? ""
      throw RuleRunnerError.invalidOutput(
        "Could not parse JSON violations from output: \(text). Error: \(error.localizedDescription)")
    }
  }
}
