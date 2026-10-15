public import Foundation

/// Builds and executes Swift and TypeScript rule processes according to the engine process contract.
public struct RuleRunner: Sendable {
  public let environment: SystemEnvironment
  private let runner: SubprocessRunner
  public var timeoutSeconds: Double

  public init(
    environment: SystemEnvironment = .standard,
    runner: SubprocessRunner = SubprocessRunner(),
    timeoutSeconds: Double = SubprocessRunner.defaultTimeoutSeconds
  ) {
    self.environment = environment
    self.runner = runner
    self.timeoutSeconds = timeoutSeconds
  }

  /// Executes a rule for a given target language and returns parsed violations.
  public func execute(
    target: TargetLanguage,
    ruleDirectory: URL,
    ruleTreeHash: String,
    request: RuleRequest,
    engineVersion: String = "1.0.0"
  ) async throws(RuleRunnerError) -> [ReportedViolation] {
    switch target {
    case .swift:
      return try await executeSwiftRule(
        ruleDirectory: ruleDirectory,
        ruleTreeHash: ruleTreeHash,
        request: request,
        engineVersion: engineVersion
      )
    case .ts:
      return try await executeTSRule(
        ruleDirectory: ruleDirectory,
        request: request
      )
    }
  }

  // MARK: - Swift Rules

  private func executeSwiftRule(
    ruleDirectory: URL,
    ruleTreeHash: String,
    request: RuleRequest,
    engineVersion: String
  ) async throws(RuleRunnerError) -> [ReportedViolation] {
    let fm = FileManager.default
    let cachesURL: URL
    if let userCache = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
      cachesURL = userCache.appendingPathComponent("invariants/rules/\(engineVersion)/\(ruleTreeHash)")
    } else {
      cachesURL = fm.temporaryDirectory.appendingPathComponent("invariants_cache/\(engineVersion)/\(ruleTreeHash)")
    }

    let binaryURL = cachesURL.appendingPathComponent(".build/release/RuleExecutable")
    if !fm.fileExists(atPath: binaryURL.path) {
      try await buildSwiftRule(
        ruleDirectory: ruleDirectory,
        cacheDirectory: cachesURL
      )
    }

    // Write request.json to temp file
    let requestURL = cachesURL.appendingPathComponent("request_\(UUID().uuidString).json")
    defer {
      try? fm.removeItem(at: requestURL)
    }

    do {
      let data = try JSONEncoder().encode(request)
      try data.write(to: requestURL, options: .atomic)
    } catch {
      throw RuleRunnerError.systemError("Failed to write request.json: \(error.localizedDescription)")
    }

    let output: ProcessOutput
    do {
      output = try await runner.run(
        executableURL: binaryURL,
        arguments: ["--request", requestURL.path],
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
    if stderr.contains("INDEX STALE") || output.stdoutString.contains("INDEX STALE") {
      throw RuleRunnerError.indexStale(stderr.isEmpty ? output.stdoutString : stderr)
    }

    guard output.exitCode == 0 else {
      throw RuleRunnerError.ruleCrashed(exitCode: output.exitCode, stderr: stderr)
    }

    return try parseViolations(from: output.stdoutData)
  }

  private func buildSwiftRule(ruleDirectory: URL, cacheDirectory: URL) async throws(RuleRunnerError) {
    let fm = FileManager.default
    let sourcesDir = cacheDirectory.appendingPathComponent("Sources")

    do {
      try fm.createDirectory(at: sourcesDir, withIntermediateDirectories: true)
    } catch {
      throw RuleRunnerError.executableBuildFailed("Failed to create build cache dir: \(error.localizedDescription)")
    }

    // Copy all .swift files from ruleDirectory (excluding fixture directories)
    guard
      let enumerator = fm.enumerator(
        at: ruleDirectory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
    else {
      throw RuleRunnerError.executableBuildFailed("Cannot enumerate rule directory \(ruleDirectory.path)")
    }

    let ruleDirPath = ruleDirectory.standardizedFileURL.path
    while let fileURL = enumerator.nextObject() as? URL {
      let path = fileURL.standardizedFileURL.path
      guard fileURL.pathExtension == "swift" else { continue }

      var rel = String(path.dropFirst(ruleDirPath.count))
      if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }

      if rel.hasPrefix("should_pass/") || rel.hasPrefix("should_fail/") {
        continue
      }

      let destURL = sourcesDir.appendingPathComponent(fileURL.lastPathComponent)
      do {
        if fm.fileExists(atPath: destURL.path) {
          try fm.removeItem(at: destURL)
        }
        try fm.copyItem(at: fileURL, to: destURL)
      } catch {
        throw RuleRunnerError.executableBuildFailed(
          "Failed to copy swift file \(fileURL.lastPathComponent): \(error.localizedDescription)")
      }
    }

    // Find kit-swift path
    let kitSwiftURL = resolveKitSwiftURL()
    guard fm.fileExists(atPath: kitSwiftURL.path) else {
      throw RuleRunnerError.kitNotFound("kit-swift not found at \(kitSwiftURL.path)")
    }

    let kitPackageName = (kitSwiftURL.lastPathComponent == "kit-swift") ? "kit-swift" : "invariants"

    let kitResolved = kitSwiftURL.appendingPathComponent("Package.resolved")
    let targetResolved = cacheDirectory.appendingPathComponent("Package.resolved")
    if fm.fileExists(atPath: kitResolved.path) && !fm.fileExists(atPath: targetResolved.path) {
      try? fm.copyItem(at: kitResolved, to: targetResolved)
    }

    let packageManifest = """
      // swift-tools-version: 6.0
      import PackageDescription

      let package = Package(
          name: "RuleExecutable",
          platforms: [.macOS(.v14)],
          dependencies: [
              .package(path: "\(kitSwiftURL.path)")
          ],
          targets: [
              .executableTarget(
                  name: "RuleExecutable",
                  dependencies: [
                      .product(name: "InvariantKit", package: "\(kitPackageName)")
                  ],
                  path: "Sources"
              )
          ]
      )
      """

    let manifestURL = cacheDirectory.appendingPathComponent("Package.swift")
    do {
      try packageManifest.data(using: .utf8)?.write(to: manifestURL, options: .atomic)
    } catch {
      throw RuleRunnerError.executableBuildFailed("Failed to write Package.swift: \(error.localizedDescription)")
    }

    // Build with xcrun swift build -c release
    let buildOutput: ProcessOutput
    do {
      buildOutput = try await runner.run(
        executableURL: SubprocessRunner.xcrunURL,
        arguments: ["swift", "build", "-c", "release", "--package-path", cacheDirectory.path],
        workingDirectory: cacheDirectory,
        timeoutSeconds: timeoutSeconds
      )
    } catch {
      throw RuleRunnerError.executableBuildFailed("swift build invocation error: \(error)")
    }

    guard buildOutput.exitCode == 0 else {
      throw RuleRunnerError.executableBuildFailed(
        "swift build failed (code \(buildOutput.exitCode)): \(buildOutput.stderrString)")
    }
  }

  private func resolveKitSwiftURL() -> URL {
    if FileManager.default.fileExists(atPath: environment.kitSwiftURL.path) {
      return environment.kitSwiftURL
    }
    if let execURL = Bundle.main.executableURL {
      let candidate = execURL.deletingLastPathComponent().appendingPathComponent("kit-swift")
      if FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
      }
    }
    // In local development / tests: use current repo root
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  }

  // MARK: - TypeScript Rules

  private func executeTSRule(
    ruleDirectory: URL,
    request: RuleRequest
  ) async throws(RuleRunnerError) -> [ReportedViolation] {
    guard let nodeURL = SubprocessRunner.resolveNodeURL() else {
      throw RuleRunnerError.nodeNotFound
    }

    let ruleTsURL = ruleDirectory.appendingPathComponent("rule.ts")
    guard FileManager.default.fileExists(atPath: ruleTsURL.path) else {
      throw RuleRunnerError.kitNotFound("rule.ts not found at \(ruleTsURL.path)")
    }

    let runnerJsURL = resolveRunnerJSURL()
    guard FileManager.default.fileExists(atPath: runnerJsURL.path) else {
      throw RuleRunnerError.kitNotFound("kit-ts runner not found at \(runnerJsURL.path)")
    }

    let tempReqURL = FileManager.default.temporaryDirectory.appendingPathComponent("ts_req_\(UUID().uuidString).json")
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
        executableURL: nodeURL,
        arguments: [runnerJsURL.path, ruleTsURL.path, tempReqURL.path],
        workingDirectory: URL(fileURLWithPath: request.repoRoot),
        timeoutSeconds: timeoutSeconds
      )
    } catch let sysErr {
      switch sysErr {
      case .processTimedOut(_, let timeout):
        throw RuleRunnerError.ruleHung(timeoutSeconds: timeout)
      default:
        throw RuleRunnerError.systemError("TS subprocess error: \(sysErr)")
      }
    }

    guard output.exitCode == 0 else {
      throw RuleRunnerError.ruleCrashed(exitCode: output.exitCode, stderr: output.stderrString)
    }

    return try parseViolations(from: output.stdoutData)
  }

  private func resolveRunnerJSURL() -> URL {
    let installed = environment.kitTsURL.appendingPathComponent("dist/runner.js")
    if FileManager.default.fileExists(atPath: installed.path) {
      return installed
    }
    if let execURL = Bundle.main.executableURL {
      let candidate = execURL.deletingLastPathComponent().appendingPathComponent("kit-ts/dist/runner.js")
      if FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
      }
    }
    // Local repo fallback
    let localDist = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(
      "kit-ts/dist/runner.js")
    if FileManager.default.fileExists(atPath: localDist.path) {
      return localDist
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("kit-ts/src/runner.ts")
  }

  private func parseViolations(from data: Data) throws(RuleRunnerError) -> [ReportedViolation] {
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
