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

  func executeProcessAndParseViolations(
    executableURL: URL,
    arguments: (URL) -> [String],
    request: RuleRequest,
    reporting: RuleReportingProtocol,
    timeoutSeconds: Double
  ) async throws(RuleRunnerError) -> [ReportedViolation] {
    let fm = FileManager.default
    let tempReqURL = fm.temporaryDirectory.appendingPathComponent("req_\(UUID().uuidString).json")
    defer {
      try? fm.removeItem(at: tempReqURL)
    }

    do {
      let data = try JSONEncoder().encode(request)
      try data.write(to: tempReqURL, options: .atomic)
    } catch {
      throw RuleRunnerError.systemError("Failed to write request JSON: \(error.localizedDescription)")
    }

    let output: ProcessOutput
    do {
      output = try await SubprocessRunner.run(
        executableURL: executableURL,
        arguments: arguments(tempReqURL),
        workingDirectory: URL(fileURLWithPath: request.repoRoot),
        timeoutSeconds: timeoutSeconds
      )
    } catch let sysErr {
      switch sysErr {
      case .processTimedOut(_, let timeout):
        throw RuleRunnerError.ruleHung(timeoutSeconds: timeout)
      default:
        throw RuleRunnerError.systemError("Execution error: \(sysErr)")
      }
    }

    let stderr = output.stderrString
    if let marker = reporting.staleIndexStderrMarker {
      if stderr.contains(marker) || output.stdoutString.contains(marker) {
        throw RuleRunnerError.indexStale(stderr.isEmpty ? output.stdoutString : stderr)
      }
    }

    if output.exitCode == reporting.staleIndexExitCode {
      throw RuleRunnerError.indexStale(stderr.isEmpty ? output.stdoutString : stderr)
    }

    guard output.exitCode == reporting.successExitCode else {
      throw RuleRunnerError.ruleCrashed(exitCode: output.exitCode, stderr: stderr)
    }

    return try parseViolations(from: output.stdoutData)
  }
}
