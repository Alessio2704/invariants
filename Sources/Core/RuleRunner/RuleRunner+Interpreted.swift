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

    return try await executeProcessAndParseViolations(
      executableURL: runtimeURL,
      arguments: { [runnerScriptURL.path, ruleFileURL.path, $0.path] },
      request: request,
      reporting: reporting,
      timeoutSeconds: timeoutSeconds
    )
  }

  func resolveKitURL(named name: String) -> URL {
    let installed = environment.kitURL(named: name)
    if FileManager.default.fileExists(atPath: installed.path) {
      return installed
    }
    if let execURL = Bundle.main.executableURL {
      let kitsCandidate = execURL.deletingLastPathComponent()
        .appendingPathComponent(SystemPaths.kitsDirectorySubpath)
        .appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: kitsCandidate.path) {
        return kitsCandidate
      }
      let candidate = execURL.deletingLastPathComponent().appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
      }
    }
    // Check discovered repo root (for Xcode test runner & local dev)
    if let discoveredRoot = try? RepoLocator.discover() {
      let kitsCandidate =
        discoveredRoot
        .appendingPathComponent(SystemPaths.kitsDirectorySubpath)
        .appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: kitsCandidate.path) {
        return kitsCandidate
      }
      let candidate = discoveredRoot.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
      }
    }
    // In local development / tests: check current working directory
    let localKitsCandidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent(SystemPaths.kitsDirectorySubpath)
      .appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: localKitsCandidate.path) {
      return localKitsCandidate
    }
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
    let localKitsDist = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(
      "\(SystemPaths.kitsDirectorySubpath)/\(spec.kitDirectoryName)/\(spec.kitRunnerRelativePath)")
    if FileManager.default.fileExists(atPath: localKitsDist.path) {
      return localKitsDist
    }
    let localKitsDev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(
      "\(SystemPaths.kitsDirectorySubpath)/\(spec.kitDirectoryName)/\(spec.devRunnerRelativePath)")
    if FileManager.default.fileExists(atPath: localKitsDev.path) {
      return localKitsDev
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
        if let path = String(bytes: data, encoding: .utf8)?.trimmed {
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
