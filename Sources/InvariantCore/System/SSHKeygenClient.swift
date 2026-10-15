public import Foundation

/// SSH keygen client wrapping `/usr/bin/ssh-keygen`.
public struct SSHKeygenClient: Sendable {
  private let runner: SubprocessRunner

  public init(runner: SubprocessRunner = SubprocessRunner()) {
    self.runner = runner
  }

  /// Signs a file using `ssh-keygen -Y sign -f <keyPath> -n <namespace> <file>`.
  /// Produces `<file>.sig`.
  public func sign(
    keyURL: URL,
    namespace: String = "invariants",
    fileURL: URL
  ) async throws(SystemError) {
    let output = try await runner.run(
      executableURL: SubprocessRunner.sshKeygenURL,
      arguments: ["-Y", "sign", "-f", keyURL.path, "-n", namespace, fileURL.path],
      workingDirectory: fileURL.deletingLastPathComponent()
    )
    guard output.exitCode == 0 else {
      throw SystemError.processFailed(
        executable: SubprocessRunner.sshKeygenURL.path,
        arguments: ["-Y", "sign", "-f", keyURL.path, "-n", namespace, fileURL.path],
        exitCode: output.exitCode,
        stderr: output.stderrString
      )
    }
  }

  /// Verifies a file signature using `ssh-keygen -Y verify -f <allowedSigners> -I <identity> -n <namespace> -s <sigFile> < <file>`.
  public func verify(
    allowedSignersURL: URL,
    identity: String = "owner",
    namespace: String = "invariants",
    signatureURL: URL,
    fileURL: URL
  ) async throws(SystemError) -> Bool {
    guard FileManager.default.fileExists(atPath: allowedSignersURL.path) else {
      return false
    }
    guard FileManager.default.fileExists(atPath: signatureURL.path) else {
      return false
    }
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return false
    }

    let fileData: Data
    do {
      fileData = try Data(contentsOf: fileURL)
    } catch {
      throw SystemError.fileIOError("Failed to read file for verification: \(error.localizedDescription)")
    }

    let output = try await runner.run(
      executableURL: SubprocessRunner.sshKeygenURL,
      arguments: [
        "-Y", "verify",
        "-f", allowedSignersURL.path,
        "-I", identity,
        "-n", namespace,
        "-s", signatureURL.path,
      ],
      stdinData: fileData
    )
    return output.exitCode == 0
  }

  /// Generates a throwaway Ed25519 keypair for testing or initialization without passphrase.
  public func generateThrowawayKey(at keyURL: URL) async throws(SystemError) {
    let output = try await runner.run(
      executableURL: SubprocessRunner.sshKeygenURL,
      arguments: ["-t", "ed25519", "-N", "", "-f", keyURL.path]
    )
    guard output.exitCode == 0 else {
      throw SystemError.processFailed(
        executable: SubprocessRunner.sshKeygenURL.path,
        arguments: ["-t", "ed25519", "-N", "", "-f", keyURL.path],
        exitCode: output.exitCode,
        stderr: output.stderrString
      )
    }
  }
}
