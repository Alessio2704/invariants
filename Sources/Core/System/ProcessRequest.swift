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
  public var checkExitCode: Bool
  public var elevationToken: ElevationToken?

  public init(
    executableURL: URL,
    arguments: [String] = [],
    targetURL: URL? = nil,
    workingDirectory: URL? = nil,
    environment: [String: String]? = nil,
    stdinData: Data? = nil,
    timeoutSeconds: Double = SubprocessRunner.defaultTimeoutSeconds,
    checkExitCode: Bool = false,
    elevationToken: ElevationToken? = nil
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.targetURL = targetURL
    self.workingDirectory = workingDirectory
    self.environment = environment
    self.stdinData = stdinData
    self.timeoutSeconds = timeoutSeconds
    self.checkExitCode = checkExitCode
    self.elevationToken = elevationToken
  }

  public init(
    binary: SystemBinary,
    arguments: [String] = [],
    targetURL: URL? = nil,
    workingDirectory: URL? = nil,
    environment: [String: String]? = nil,
    stdinData: Data? = nil,
    timeoutSeconds: Double = SubprocessRunner.defaultTimeoutSeconds,
    checkExitCode: Bool = false,
    elevationToken: ElevationToken? = nil
  ) {
    self.init(
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
}
