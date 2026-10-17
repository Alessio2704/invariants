public import Foundation

extension RuleRunner {
  func executeInterpretedRule(
    target: TargetLanguage,
    spec: InterpretedSpec,
    reporting: RuleReportingProtocol,
    ruleDirectory: URL,
    request: RuleRequest
  ) async throws(RuleRunnerError) -> [ReportedViolation] {
    guard let runtimeURL = Self.resolveRuntimeURL(command: spec.runtimeCommand) else {
      if spec.runtimeCommand == "node" {
        throw RuleRunnerError.nodeNotFound
      }
      throw RuleRunnerError.runtimeNotFound(spec.runtimeCommand)
    }

    let ruleFileURL = ruleDirectory.appendingPathComponent(target.spec.ruleFileName)
    guard FileManager.default.fileExists(atPath: ruleFileURL.path) else {
      throw RuleRunnerError.kitNotFound("\(target.spec.ruleFileName) not found at \(ruleFileURL.path)")
    }

    let runnerScriptURL = resolveInterpretedRunnerURL(spec: spec)
    guard FileManager.default.fileExists(atPath: runnerScriptURL.path) else {
      throw RuleRunnerError.kitNotFound("\(spec.kitDirectoryName) runner not found at \(runnerScriptURL.path)")
    }

    let tempReqURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "req_\(UUID().uuidString).json"
    )
    defer {
      try? FileManager.default.removeItem(at: tempReqURL)
    }

    do {
      let data = try JSONEncoder().encode(request)
      try data.write(to: tempReqURL, options: .atomic)
    } catch {
      throw RuleRunnerError.systemError("Failed to write request JSON: \(error.localizedDescription)")
    }

    let output: ProcessOutput
    do {
      output = try await runner.run(
        executableURL: runtimeURL,
        arguments: [runnerScriptURL.path, ruleFileURL.path, tempReqURL.path],
        workingDirectory: URL(fileURLWithPath: request.repoRoot),
        timeoutSeconds: timeoutSeconds
      )
    } catch let sysErr {
      switch sysErr {
      case .processTimedOut(_, let timeout):
        throw RuleRunnerError.ruleHung(timeoutSeconds: timeout)
      default:
        throw RuleRunnerError.systemError("Interpreted subprocess error: \(sysErr)")
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
      throw RuleRunnerError.ruleCrashed(exitCode: output.exitCode, stderr: output.stderrString)
    }

    return try parseViolations(from: output.stdoutData)
  }

  func resolveKitURL(named name: String) -> URL {
    let installed = environment.currentVersionURL.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: installed.path) {
      return installed
    }
    if let execURL = Bundle.main.executableURL {
      let candidate = execURL.deletingLastPathComponent().appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
      }
    }
    // Check compile-time source repo root (for Xcode test runner & local dev)
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let candidate = repoRoot.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: candidate.path) {
      return candidate
    }
    if FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("Package.swift").path) {
      return repoRoot
    }
    // In local development / tests: use current repo root
    let localCandidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: localCandidate.path) {
      return localCandidate
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  }

  func resolveInterpretedRunnerURL(spec: InterpretedSpec) -> URL {
    let kitURL = resolveKitURL(named: spec.kitDirectoryName)
    let distRunner = kitURL.appendingPathComponent(spec.kitRunnerRelativePath)
    if FileManager.default.fileExists(atPath: distRunner.path) {
      return distRunner
    }
    let devRunner = kitURL.appendingPathComponent(spec.devRunnerRelativePath)
    if FileManager.default.fileExists(atPath: devRunner.path) {
      return devRunner
    }
    let localDist = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(
      "\(spec.kitDirectoryName)/\(spec.kitRunnerRelativePath)")
    if FileManager.default.fileExists(atPath: localDist.path) {
      return localDist
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(
      "\(spec.kitDirectoryName)/\(spec.devRunnerRelativePath)")
  }

  /// Resolves the absolute path to a runtime binary by command name.
  public static func resolveRuntimeURL(command: String) -> URL? {
    let fm = FileManager.default

    // 1. Query /usr/bin/which <command>
    let whichProcess = Process()
    whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    whichProcess.arguments = [command]
    let pipe = Pipe()
    whichProcess.standardOutput = pipe
    whichProcess.standardError = Pipe()
    if (try? whichProcess.run()) != nil {
      whichProcess.waitUntilExit()
      if whichProcess.terminationStatus == 0 {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let path = String(bytes: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
          if !path.isEmpty && fm.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
          }
        }
      }
    }

    // 2. Standard location candidates
    let candidates = [
      "/opt/homebrew/bin/\(command)",
      "/usr/local/bin/\(command)",
      "/usr/bin/\(command)",
    ]
    for candidate in candidates where fm.fileExists(atPath: candidate) {
      return URL(fileURLWithPath: candidate)
    }
    return nil
  }
}
