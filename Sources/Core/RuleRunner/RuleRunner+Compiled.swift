import Foundation

extension RuleRunner {
  func executeCompiledRule(
    spec: RuleExecutionSpec,
    ruleDirectory: URL,
    ruleTreeHash: String,
    request: RuleRequest
  ) async throws(RuleRunnerError) -> [ReportedViolation] {
    guard case .compiled(let compiled) = spec.model else { return [] }
    let reporting = spec.reporting

    let fm = FileManager.default
    let engineVersion = EngineVersion.current
    let cachesURL: URL
    if let userCache = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
      cachesURL = userCache.appendingPathComponent("invariants/rules/\(engineVersion)/\(ruleTreeHash)")
    } else {
      cachesURL = fm.temporaryDirectory.appendingPathComponent("invariants_cache/\(engineVersion)/\(ruleTreeHash)")
    }

    let releaseBin = cachesURL.appendingPathComponent(compiled.artifactRelativePath)
    let debugBin = compiled.debugArtifactRelativePath.map { cachesURL.appendingPathComponent($0) }
    let binaryURL: URL
    if fm.fileExists(atPath: releaseBin.path) {
      binaryURL = releaseBin
    } else if let debugBin, fm.fileExists(atPath: debugBin.path) {
      binaryURL = debugBin
    } else {
      do {
        try await CompiledRuleBuildCoordinator.shared.coordinate(key: cachesURL.path) {
          let fm = FileManager.default
          let alreadyBuilt =
            fm.fileExists(atPath: releaseBin.path)
            || (debugBin.map { fm.fileExists(atPath: $0.path) } ?? false)
          if alreadyBuilt {
            return
          }
          try await self.buildCompiledRule(
            spec: compiled,
            ruleDirectory: ruleDirectory,
            cacheDirectory: cachesURL
          )
        }
      } catch let error as RuleRunnerError {
        throw error
      } catch {
        throw RuleRunnerError.executableBuildFailed(error.localizedDescription)
      }

      if fm.fileExists(atPath: releaseBin.path) {
        binaryURL = releaseBin
      } else if let debugBin, fm.fileExists(atPath: debugBin.path) {
        binaryURL = debugBin
      } else {
        throw RuleRunnerError.executableBuildFailed(
          "Build succeeded but expected artifact was not found at \(compiled.artifactRelativePath)"
        )
      }
    }

    return try await executeProcessAndParseViolations(
      executableURL: binaryURL,
      arguments: { ["--request", $0.path] },
      request: request,
      reporting: reporting,
      timeoutSeconds: timeoutSeconds
    )
  }

  private func buildCompiledRule(
    spec: CompiledSpec,
    ruleDirectory: URL,
    cacheDirectory: URL
  ) async throws(RuleRunnerError) {
    let fm = FileManager.default
    let sourcesDir = cacheDirectory.appendingPathComponent("Sources")

    do {
      try fm.createDirectory(at: sourcesDir, withIntermediateDirectories: true)
    } catch {
      throw RuleRunnerError.executableBuildFailed("Failed to create build cache dir: \(error.localizedDescription)")
    }

    // Copy all source files matching spec.sourceExtensions (excluding fixture directories)
    guard
      let enumerator = fm.enumerator(
        at: ruleDirectory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
    else {
      throw RuleRunnerError.executableBuildFailed("Cannot enumerate rule directory \(ruleDirectory.path)")
    }

    let extSet = Set(spec.sourceExtensions)
    let ruleDirPath = ruleDirectory.standardizedFileURL.path
    while let fileURL = enumerator.nextObject() as? URL {
      let path = fileURL.standardizedFileURL.path
      guard extSet.contains(fileURL.pathExtension) else { continue }

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
          "Failed to copy source file \(fileURL.lastPathComponent): \(error.localizedDescription)")
      }
    }

    // Find kit package path
    let kitURL = resolveKitURL(named: spec.kitPackageName)
    guard fm.fileExists(atPath: kitURL.path) else {
      throw RuleRunnerError.kitNotFound("\(spec.kitPackageName) not found at \(kitURL.path)")
    }

    switch spec.manifestKind {
    case .swiftPackage(let toolsVersion, let targetName, let productName):
      let kitPackageName = (kitURL.lastPathComponent == spec.kitPackageName) ? spec.kitPackageName : "invariants"

      let kitResolved = kitURL.appendingPathComponent("Package.resolved")
      let targetResolved = cacheDirectory.appendingPathComponent("Package.resolved")
      if fm.fileExists(atPath: kitResolved.path) && !fm.fileExists(atPath: targetResolved.path) {
        try? fm.copyItem(at: kitResolved, to: targetResolved)
      } else if !fm.fileExists(atPath: targetResolved.path) {
        let rootResolved = kitURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
          "Package.resolved")
        if fm.fileExists(atPath: rootResolved.path) {
          try? fm.copyItem(at: rootResolved, to: targetResolved)
        }
      }

      let packageManifest = """
        // swift-tools-version: \(toolsVersion)
        import PackageDescription

        let package = Package(
            name: "\(targetName)",
            platforms: [.macOS(.v14)],
            dependencies: [
                .package(path: "\(kitURL.path)")
            ],
            targets: [
                .executableTarget(
                    name: "\(targetName)",
                    dependencies: [
                        .product(name: "\(productName)", package: "\(kitPackageName)")
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
    }

    // Build with toolchain
    let buildOutput: ProcessOutput
    do {
      var args = spec.buildArguments
      if args.contains("swift") {
        args.append(contentsOf: ["--package-path", cacheDirectory.path])
      }
      buildOutput = try await SubprocessRunner.run(
        binary: spec.buildToolchain,
        arguments: args,
        workingDirectory: cacheDirectory,
        timeoutSeconds: timeoutSeconds
      )
    } catch {
      throw RuleRunnerError.executableBuildFailed("\(spec.buildToolchain) build invocation error: \(error)")
    }

    guard buildOutput.exitCode == 0 else {
      throw RuleRunnerError.executableBuildFailed(
        "Build failed (code \(buildOutput.exitCode)): \(buildOutput.stderrString)")
    }
  }
}

// MARK: - In-Process Compilation Coordinator

private actor CompiledRuleBuildCoordinator {
  static let shared = CompiledRuleBuildCoordinator()

  private var inFlightBuilds: [String: Task<Void, any Error>] = [:]

  func coordinate(key: String, perform: @Sendable @escaping () async throws -> Void) async throws {
    if let existing = inFlightBuilds[key] {
      try await existing.value
      return
    }

    let task = Task {
      try await perform()
    }
    inFlightBuilds[key] = task

    do {
      try await task.value
      inFlightBuilds.removeValue(forKey: key)
    } catch {
      inFlightBuilds.removeValue(forKey: key)
      throw error
    }
  }
}
