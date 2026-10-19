public import Foundation

/// Result of executing a subprocess.
public struct ProcessOutput: Sendable, Equatable {
  public let exitCode: Int32
  public let stdoutData: Data
  public let stderrData: Data

  public var stdoutString: String {
    String(bytes: stdoutData, encoding: .utf8) ?? ""
  }

  public var stderrString: String {
    String(bytes: stderrData, encoding: .utf8) ?? ""
  }

  public var trimmedStdout: String {
    stdoutString.trimmed
  }

  public init(exitCode: Int32, stdoutData: Data, stderrData: Data) {
    self.exitCode = exitCode
    self.stdoutData = stdoutData
    self.stderrData = stderrData
  }
}

/// Strict namespace for running system binaries with absolute paths and automatic elevation support.
public enum SubprocessRunner: Sendable {
  public static let defaultTimeoutSeconds: Double = 600.0  // 10 minutes

  /// Determines whether writing to the target URL requires elevated privileges.
  public static func requiresElevation(for targetURL: URL) -> Bool {
    if FileManager.default.fileExists(atPath: targetURL.path) {
      return !FileManager.default.isWritableFile(atPath: targetURL.path)
    }

    var current = targetURL.deletingLastPathComponent()
    while !FileManager.default.fileExists(atPath: current.path) {
      let parent = current.deletingLastPathComponent()
      if parent.path == current.path { break }
      current = parent
    }

    return !FileManager.default.isWritableFile(atPath: current.path)
  }

  /// Executes a system binary described by `request`, automatically elevating via `sudo` if the target location requires it.
  @discardableResult
  public static func run(_ request: ProcessRequest) async throws(SystemError) -> ProcessOutput {
    let needsElevation: Bool
    if let targetURL = request.targetURL {
      needsElevation = requiresElevation(for: targetURL) && !Authorizer.isRunningAsRoot
    } else {
      needsElevation = false
    }

    if needsElevation {
      guard let token = request.elevationToken else {
        throw SystemError.cryptographicError(
          "Root elevation is required for \(request.targetURL?.path ?? request.executableURL.path) but no ElevationToken was provided."
        )
      }
      try token.validateFreshness()
    }

    let executable = needsElevation ? SystemBinary.sudo.url : request.executableURL
    let arguments = needsElevation ? ["-n", request.executableURL.path] + request.arguments : request.arguments

    guard FileManager.default.fileExists(atPath: executable.path) else {
      throw SystemError.executableNotFound(executable.path)
    }

    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    if let workingDirectory = request.workingDirectory {
      process.currentDirectoryURL = workingDirectory
    }
    if let environment = request.environment {
      process.environment = environment
    }

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let stdinPipe = Pipe()

    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.standardInput = stdinPipe

    do {
      try process.run()
    } catch {
      throw SystemError.fileIOError("Failed to launch process \(executable.path): \(error.localizedDescription)")
    }

    if let stdinData = request.stdinData {
      do {
        try stdinPipe.fileHandleForWriting.write(contentsOf: stdinData)
        try stdinPipe.fileHandleForWriting.close()
      } catch {
        throw SystemError.fileIOError("Failed to write stdin: \(error.localizedDescription)")
      }
    } else {
      do {
        try stdinPipe.fileHandleForWriting.close()
      } catch {
        throw SystemError.fileIOError("Failed to close stdin: \(error.localizedDescription)")
      }
    }

    let timeoutNano = UInt64(request.timeoutSeconds * 1_000_000_000)

    // Read pipe data concurrently
    let stdoutTask = Task.detached {
      stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    }
    let stderrTask = Task.detached {
      stderrPipe.fileHandleForReading.readDataToEndOfFile()
    }

    let monitorTask = Task.detached {
      do {
        try await Task.sleep(nanoseconds: timeoutNano)
        if process.isRunning {
          process.terminate()
        }
      } catch {
        // Sleep cancelled when process finishes early
      }
    }

    process.waitUntilExit()
    monitorTask.cancel()

    if !process.isRunning && process.terminationReason == .uncaughtSignal {
      // Process was terminated due to timeout
      throw SystemError.processTimedOut(executable: executable.path, timeoutSeconds: request.timeoutSeconds)
    }

    let stdoutData = await stdoutTask.value
    let stderrData = await stderrTask.value

    let output = ProcessOutput(
      exitCode: process.terminationStatus,
      stdoutData: stdoutData,
      stderrData: stderrData
    )

    if request.checkExitCode && output.exitCode != 0 {
      throw SystemError.processFailed(
        executable: executable.path,
        arguments: arguments,
        exitCode: output.exitCode,
        stderr: output.stderrString
      )
    }

    return output
  }

  /// Runs an executable using its exact URL and arguments.
  @discardableResult
  public static func run(
    executableURL: URL,
    arguments: [String] = [],
    targetURL: URL? = nil,
    workingDirectory: URL? = nil,
    environment: [String: String]? = nil,
    stdinData: Data? = nil,
    timeoutSeconds: Double = defaultTimeoutSeconds,
    checkExitCode: Bool = false,
    elevationToken: ElevationToken? = nil
  ) async throws(SystemError) -> ProcessOutput {
    try await run(
      ProcessRequest(
        executableURL: executableURL,
        arguments: arguments,
        targetURL: targetURL,
        workingDirectory: workingDirectory,
        environment: environment,
        stdinData: stdinData,
        timeoutSeconds: timeoutSeconds,
        checkExitCode: checkExitCode,
        elevationToken: elevationToken
      )
    )
  }

  /// Runs a trusted canonical system binary using its `SystemBinary` identifier.
  @discardableResult
  public static func run(
    binary: SystemBinary,
    arguments: [String] = [],
    targetURL: URL? = nil,
    workingDirectory: URL? = nil,
    environment: [String: String]? = nil,
    stdinData: Data? = nil,
    timeoutSeconds: Double = defaultTimeoutSeconds,
    checkExitCode: Bool = false,
    elevationToken: ElevationToken? = nil
  ) async throws(SystemError) -> ProcessOutput {
    try await run(
      executableURL: binary.url,
      arguments: arguments,
      targetURL: targetURL,
      workingDirectory: workingDirectory,
      environment: environment,
      stdinData: stdinData,
      timeoutSeconds: timeoutSeconds,
      checkExitCode: checkExitCode,
      elevationToken: elevationToken
    )
  }

  /// Runs a shell command via `/bin/sh -c`.
  @discardableResult
  public static func runShell(
    _ command: String,
    targetURL: URL? = nil,
    workingDirectory: URL? = nil,
    environment: [String: String]? = nil,
    stdinData: Data? = nil,
    timeoutSeconds: Double = defaultTimeoutSeconds,
    checkExitCode: Bool = false,
    elevationToken: ElevationToken? = nil
  ) async throws(SystemError) -> ProcessOutput {
    try await run(
      executableURL: SystemBinary.sh.url,
      arguments: ["-c", command],
      targetURL: targetURL,
      workingDirectory: workingDirectory,
      environment: environment,
      stdinData: stdinData,
      timeoutSeconds: timeoutSeconds,
      checkExitCode: checkExitCode,
      elevationToken: elevationToken
    )
  }
}
