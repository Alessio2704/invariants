public import Foundation

/// Privileged filesystem and command execution client wrapping operations requiring root privilege.
public struct SudoClient: ProcessRunning, Sendable {
  public let runner: SubprocessRunner

  public init(runner: SubprocessRunner = SubprocessRunner()) {
    self.runner = runner
  }

  /// Determines whether writing to the target URL requires elevated privileges.
  public func requiresElevation(for targetURL: URL) -> Bool {
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

  /// Executes a system binary or shell command, automatically elevating via `sudo`
  /// if the target location requires root privileges or if running unprivileged without a target.
  @discardableResult
  public func run(_ request: ProcessRequest) async throws(SystemError) -> ProcessOutput {
    let needsElevation: Bool
    if let targetURL = request.targetURL {
      needsElevation = requiresElevation(for: targetURL)
    } else {
      needsElevation = geteuid() != 0
    }

    let executable = needsElevation ? SubprocessRunner.sudoURL : request.executableURL
    let arguments = needsElevation ? [request.executableURL.path] + request.arguments : request.arguments

    let forwardedRequest = ProcessRequest(
      executableURL: executable,
      arguments: arguments,
      targetURL: nil,
      workingDirectory: request.workingDirectory,
      environment: request.environment,
      stdinData: request.stdinData,
      timeoutSeconds: request.timeoutSeconds
    )

    let output = try await runner.run(forwardedRequest)
    guard output.exitCode == 0 else {
      throw SystemError.processFailed(
        executable: executable.path,
        arguments: arguments,
        exitCode: output.exitCode,
        stderr: output.stderrString
      )
    }
    return output
  }

  /// Convenience wrapper to execute a shell command with root elevation if target requires it.
  @discardableResult
  public func runPrivileged(
    command: String,
    targetURL: URL,
    workingDirectory: URL? = nil,
    environment: [String: String]? = nil,
    stdinData: Data? = nil,
    timeoutSeconds: Double = SubprocessRunner.defaultTimeoutSeconds
  ) async throws(SystemError) -> ProcessOutput {
    try await runShell(
      command,
      targetURL: targetURL,
      workingDirectory: workingDirectory,
      environment: environment,
      stdinData: stdinData,
      timeoutSeconds: timeoutSeconds
    )
  }

  /// Creates a symbolic link, elevating via `sudo` only if the destination requires root privileges.
  public func createSymlink(from sourceURL: URL, to destinationURL: URL) async throws(SystemError) {
    let parent = destinationURL.deletingLastPathComponent()
    let command = "mkdir -p '\(parent.path)' && ln -sfn '\(sourceURL.path)' '\(destinationURL.path)'"
    _ = try await runPrivileged(command: command, targetURL: destinationURL)
  }

  /// Removes a file, symbolic link, or directory at the specified target URL.
  public func removeItem(at targetURL: URL) async throws(SystemError) {
    let exists =
      FileManager.default.fileExists(atPath: targetURL.path)
      || (try? targetURL.checkResourceIsReachable()) == true
    guard exists else { return }

    let command = "rm -rf '\(targetURL.path)'"
    _ = try await runPrivileged(command: command, targetURL: targetURL)
  }
}
