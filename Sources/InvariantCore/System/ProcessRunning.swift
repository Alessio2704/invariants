public import Foundation

/// Encapsulates the execution parameters for a system process or shell invocation.
public struct ProcessRequest: Sendable, Equatable {
  public var executableURL: URL
  public var arguments: [String]
  public var targetURL: URL?
  public var workingDirectory: URL?
  public var environment: [String: String]?
  public var stdinData: Data?
  public var timeoutSeconds: Double

  public init(
    executableURL: URL,
    arguments: [String] = [],
    targetURL: URL? = nil,
    workingDirectory: URL? = nil,
    environment: [String: String]? = nil,
    stdinData: Data? = nil,
    timeoutSeconds: Double = SubprocessRunner.defaultTimeoutSeconds
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.targetURL = targetURL
    self.workingDirectory = workingDirectory
    self.environment = environment
    self.stdinData = stdinData
    self.timeoutSeconds = timeoutSeconds
  }
}

/// Protocol for running system processes, enabling dependency injection and privileged execution polymorphism.
public protocol ProcessRunning: Sendable {
  /// Executes a system binary described by `request`.
  @discardableResult
  func run(_ request: ProcessRequest) async throws(SystemError) -> ProcessOutput
}

extension ProcessRunning {
  /// Runs an executable using its exact URL and arguments.
  @discardableResult
  public func run(
    executableURL: URL,
    arguments: [String] = [],
    targetURL: URL? = nil,
    workingDirectory: URL? = nil,
    environment: [String: String]? = nil,
    stdinData: Data? = nil,
    timeoutSeconds: Double = SubprocessRunner.defaultTimeoutSeconds
  ) async throws(SystemError) -> ProcessOutput {
    try await run(
      ProcessRequest(
        executableURL: executableURL,
        arguments: arguments,
        targetURL: targetURL,
        workingDirectory: workingDirectory,
        environment: environment,
        stdinData: stdinData,
        timeoutSeconds: timeoutSeconds
      )
    )
  }

  /// Runs a shell command via `/bin/sh -c`.
  @discardableResult
  public func runShell(
    _ command: String,
    targetURL: URL? = nil,
    workingDirectory: URL? = nil,
    environment: [String: String]? = nil,
    stdinData: Data? = nil,
    timeoutSeconds: Double = SubprocessRunner.defaultTimeoutSeconds
  ) async throws(SystemError) -> ProcessOutput {
    try await run(
      ProcessRequest(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", command],
        targetURL: targetURL,
        workingDirectory: workingDirectory,
        environment: environment,
        stdinData: stdinData,
        timeoutSeconds: timeoutSeconds
      )
    )
  }
}
