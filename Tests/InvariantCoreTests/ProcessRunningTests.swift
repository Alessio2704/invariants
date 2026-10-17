import Foundation
import Testing

@testable import InvariantCore

@Suite("ProcessRunning Protocol & ProcessRequest", .tags(.unit))
struct ProcessRunningTests {
  @Test("ProcessRequest equality and default values")
  func processRequestProperties() {
    let url = URL(fileURLWithPath: "/bin/echo")
    let req1 = ProcessRequest(executableURL: url, arguments: ["hello"])
    let req2 = ProcessRequest(executableURL: url, arguments: ["hello"])

    #expect(req1 == req2)
    #expect(req1.targetURL == nil)
    #expect(req1.workingDirectory == nil)
    #expect(req1.environment == nil)
    #expect(req1.stdinData == nil)
    #expect(req1.timeoutSeconds == SubprocessRunner.defaultTimeoutSeconds)

    var req3 = req1
    req3.arguments = ["world"]
    #expect(req1 != req3)
  }

  @Test("SubprocessRunner executes ProcessRequest directly")
  func subprocessRunnerExecutesRequest() async throws {
    let runner = SubprocessRunner()
    let request = ProcessRequest(
      executableURL: URL(fileURLWithPath: "/bin/echo"),
      arguments: ["process_running_test"]
    )
    let output = try await runner.run(request)
    #expect(output.exitCode == 0)
    #expect(output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "process_running_test")
  }

  @Test("SubprocessRunner executes runShell convenience method")
  func subprocessRunnerRunShell() async throws {
    let runner = SubprocessRunner()
    let output = try await runner.runShell("echo 'shell_test'")
    #expect(output.exitCode == 0)
    #expect(output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "shell_test")
  }

  @Test("SubprocessRunner executes ProcessRequest directly in sandbox with targetURL")
  func subprocessRunnerDirectInSandbox() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let runner = SubprocessRunner()
    let request = ProcessRequest(
      executableURL: URL(fileURLWithPath: "/bin/echo"),
      arguments: ["runner_direct_test"],
      targetURL: tmpDir
    )
    let output = try await runner.run(request)
    #expect(output.exitCode == 0)
    #expect(output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "runner_direct_test")
  }

  @Test("SubprocessRunner executes runShell convenience method in sandbox with targetURL")
  func subprocessRunnerRunShellInSandbox() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let runner = SubprocessRunner()
    let output = try await runner.runShell("echo 'runner_shell_test'", targetURL: tmpDir)
    #expect(output.exitCode == 0)
    #expect(output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "runner_shell_test")
  }

  @Test("Polymorphic execution with any ProcessRunning")
  func polymorphicExecution() async throws {
    final class MockRunner: ProcessRunning, @unchecked Sendable {
      func run(_ request: ProcessRequest) async throws(SystemError) -> ProcessOutput {
        ProcessOutput(exitCode: 0, stdoutData: Data("polymorphic\n".utf8), stderrData: Data())
      }
    }

    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let runners: [any ProcessRunning] = [
      SubprocessRunner(),
      MockRunner(),
    ]

    for runner in runners {
      let output = try await runner.runShell("echo 'polymorphic'", targetURL: tmpDir)
      #expect(output.exitCode == 0)
      #expect(output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "polymorphic")
    }
  }

  @Test("Mock ProcessRunning captures ProcessRequest accurately")
  func mockProcessRunner() async throws {
    final class MockRunner: ProcessRunning, @unchecked Sendable {
      var recordedRequests: [ProcessRequest] = []

      func run(_ request: ProcessRequest) async throws(SystemError) -> ProcessOutput {
        recordedRequests.append(request)
        return ProcessOutput(exitCode: 0, stdoutData: Data("mocked".utf8), stderrData: Data())
      }
    }

    let mock = MockRunner()
    let expectedURL = URL(fileURLWithPath: "/bin/echo")
    let output = try await mock.run(executableURL: expectedURL, arguments: ["arg1", "arg2"])

    #expect(output.stdoutString == "mocked")
    #expect(mock.recordedRequests.count == 1)
    #expect(mock.recordedRequests.first?.executableURL == expectedURL)
    #expect(mock.recordedRequests.first?.arguments == ["arg1", "arg2"])
  }

  @Test("checkExitCode false returns ProcessOutput on non-zero exit without throwing")
  func checkExitCodeFalseReturnsOutput() async throws {
    let runner = SubprocessRunner()
    let output = try await runner.runShell("exit 42", checkExitCode: false)
    #expect(output.exitCode == 42)
  }

  @Test("checkExitCode true throws processFailed on non-zero exit")
  func checkExitCodeTrueThrows() async throws {
    let runner = SubprocessRunner()
    await #expect(throws: SystemError.self) {
      try await runner.runShell("exit 42", checkExitCode: true)
    }
  }
}
