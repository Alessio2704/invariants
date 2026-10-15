import Foundation

/// Sudo client wrapping operations requiring root privilege.
public struct SudoClient: Sendable {
  private let runner: SubprocessRunner

  public init(runner: SubprocessRunner = SubprocessRunner()) {
    self.runner = runner
  }

  /// Writes the floor version for a repo to the environment's floors directory.
  /// If running against standard `/usr/local/invariants`, uses `/usr/bin/sudo`.
  /// In sandboxed/test environments, writes directly via FileManager.
  public func writeFloor(repo: String, version: Int, environment: SystemEnvironment) async throws(SystemError) {
    let floorsDir = environment.floorsDirectoryURL
    let floorFile = floorsDir.appendingPathComponent(repo)
    let content = "\(version)\n"

    if environment.rootURL.path.hasPrefix("/usr/local/invariants") {
      // Production path requires sudo
      let command = "mkdir -p '\(floorsDir.path)' && printf '%s\n' '\(version)' > '\(floorFile.path)'"
      let output = try await runner.run(
        executableURL: SubprocessRunner.sudoURL,
        arguments: ["/bin/sh", "-c", command]
      )
      guard output.exitCode == 0 else {
        throw SystemError.processFailed(
          executable: SubprocessRunner.sudoURL.path,
          arguments: ["/bin/sh", "-c", command],
          exitCode: output.exitCode,
          stderr: output.stderrString
        )
      }
    } else {
      // Custom test directory: write directly
      do {
        try FileManager.default.createDirectory(at: floorsDir, withIntermediateDirectories: true)
        guard let data = content.data(using: .utf8) else {
          throw SystemError.fileIOError("Failed to encode floor content as UTF-8")
        }
        try data.write(to: floorFile, options: .atomic)
      } catch let error as SystemError {
        throw error
      } catch {
        throw SystemError.fileIOError("Failed to write floor file at \(floorFile.path): \(error.localizedDescription)")
      }
    }
  }
}
