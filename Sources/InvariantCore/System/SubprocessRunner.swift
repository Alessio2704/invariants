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

  public init(exitCode: Int32, stdoutData: Data, stderrData: Data) {
    self.exitCode = exitCode
    self.stdoutData = stdoutData
    self.stderrData = stderrData
  }
}

/// Strict wrapper for running system binaries with absolute paths.
public struct SubprocessRunner: ProcessRunning, Sendable {
  public static let gitURL = URL(fileURLWithPath: "/usr/bin/git")
  public static let sshKeygenURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
  public static let xcrunURL = URL(fileURLWithPath: "/usr/bin/xcrun")
  public static let sudoURL = URL(fileURLWithPath: "/usr/bin/sudo")

  public static let defaultTimeoutSeconds: Double = 600.0  // 10 minutes

  public init() {}

  /// Executes a system binary described by `request`.
  @discardableResult
  public func run(_ request: ProcessRequest) async throws(SystemError) -> ProcessOutput {
    guard FileManager.default.fileExists(atPath: request.executableURL.path) else {
      throw SystemError.executableNotFound(request.executableURL.path)
    }

    let process = Process()
    process.executableURL = request.executableURL
    process.arguments = request.arguments
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
      throw SystemError.fileIOError(
        "Failed to launch process \(request.executableURL.path): \(error.localizedDescription)")
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
      throw SystemError.processTimedOut(executable: request.executableURL.path, timeoutSeconds: request.timeoutSeconds)
    }

    let stdoutData = await stdoutTask.value
    let stderrData = await stderrTask.value

    return ProcessOutput(
      exitCode: process.terminationStatus,
      stdoutData: stdoutData,
      stderrData: stderrData
    )
  }
}
