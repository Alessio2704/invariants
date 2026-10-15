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
public struct SubprocessRunner: Sendable {
  public static let gitURL = URL(fileURLWithPath: "/usr/bin/git")
  public static let sshKeygenURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
  public static let xcrunURL = URL(fileURLWithPath: "/usr/bin/xcrun")
  public static let sudoURL = URL(fileURLWithPath: "/usr/bin/sudo")

  public static let defaultTimeoutSeconds: Double = 600.0  // 10 minutes

  public init() {}

  /// Resolves the absolute path to node.
  public static func resolveNodeURL() -> URL? {
    let fm = FileManager.default

    // 1. Query /usr/bin/which node
    let whichProcess = Process()
    whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    whichProcess.arguments = ["node"]
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
      "/opt/homebrew/bin/node",
      "/usr/local/bin/node",
      "/usr/bin/node",
    ]
    for candidate in candidates where fm.fileExists(atPath: candidate) {
      return URL(fileURLWithPath: candidate)
    }
    return nil
  }

  /// Runs an executable using its exact absolute URL.
  public func run(
    executableURL: URL,
    arguments: [String],
    workingDirectory: URL? = nil,
    environment: [String: String]? = nil,
    stdinData: Data? = nil,
    timeoutSeconds: Double = defaultTimeoutSeconds
  ) async throws(SystemError) -> ProcessOutput {
    guard FileManager.default.fileExists(atPath: executableURL.path) else {
      throw SystemError.executableNotFound(executableURL.path)
    }

    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    if let workingDirectory {
      process.currentDirectoryURL = workingDirectory
    }
    if let environment {
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
      throw SystemError.fileIOError("Failed to launch process \(executableURL.path): \(error.localizedDescription)")
    }

    if let stdinData {
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

    let timeoutNano = UInt64(timeoutSeconds * 1_000_000_000)

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
      throw SystemError.processTimedOut(executable: executableURL.path, timeoutSeconds: timeoutSeconds)
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
