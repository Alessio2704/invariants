import Foundation
import Testing

@testable import InvariantCore

@Suite("SubprocessRunner & ProcessRequest Tests", .tags(.unit))
struct SubprocessRunnerTests {
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
    let request = ProcessRequest(
      executableURL: URL(fileURLWithPath: "/bin/echo"),
      arguments: ["process_running_test"]
    )
    let output = try await SubprocessRunner.run(request)
    #expect(output.exitCode == 0)
    #expect(output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "process_running_test")
  }

  @Test("SubprocessRunner executes runShell convenience method")
  func subprocessRunnerRunShell() async throws {
    let output = try await SubprocessRunner.runShell("echo 'shell_test'")
    #expect(output.exitCode == 0)
    #expect(output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "shell_test")
  }

  @Test("SubprocessRunner executes ProcessRequest directly in sandbox with targetURL")
  func subprocessRunnerDirectInSandbox() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let request = ProcessRequest(
      executableURL: URL(fileURLWithPath: "/bin/echo"),
      arguments: ["runner_direct_test"],
      targetURL: tmpDir
    )
    let output = try await SubprocessRunner.run(request)
    #expect(output.exitCode == 0)
    #expect(output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "runner_direct_test")
  }

  @Test("SubprocessRunner executes runShell convenience method in sandbox with targetURL")
  func subprocessRunnerRunShellInSandbox() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let output = try await SubprocessRunner.runShell("echo 'runner_shell_test'", targetURL: tmpDir)
    #expect(output.exitCode == 0)
    #expect(output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "runner_shell_test")
  }

  @Test("SubprocessRunner executes SystemBinary directly")
  func subprocessRunnerSystemBinary() async throws {
    let output = try await SubprocessRunner.run(binary: .git, arguments: ["--version"])
    #expect(output.exitCode == 0)
    #expect(output.stdoutString.contains("git version"))
  }

  @Test("checkExitCode false returns ProcessOutput on non-zero exit without throwing")
  func checkExitCodeFalseReturnsOutput() async throws {
    let output = try await SubprocessRunner.runShell("exit 42", checkExitCode: false)
    #expect(output.exitCode == 42)
  }

  @Test("checkExitCode true throws processFailed on non-zero exit")
  func checkExitCodeTrueThrows() async throws {
    await #expect(throws: SystemError.self) {
      try await SubprocessRunner.runShell("exit 42", checkExitCode: true)
    }
  }
}
