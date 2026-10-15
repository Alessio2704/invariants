import Foundation

/// Sudo client wrapping operations requiring root privilege.
public struct SudoClient: Sendable {
  private let runner: SubprocessRunner

  public init(runner: SubprocessRunner = SubprocessRunner()) {
    self.runner = runner
  }

  /// Determines whether writing to the target URL requires elevated privileges.
  func requiresElevation(for targetURL: URL) -> Bool {
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

  /// Writes the floor version for a repo to the environment's floors directory.
  /// Dynamically elevates to `sudo` if writing requires root privilege,
  /// or writes directly via `FileManager` if the target is already writable.
  public func writeFloor(repo: String, version: Int, environment: SystemEnvironment) async throws(SystemError) {
    let floorsDir = environment.floorsDirectoryURL
    let floorFile = floorsDir.appendingPathComponent(repo)
    let content = "\(version)\n"

    if requiresElevation(for: floorFile) {
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
      // Writable directory (sandboxes, tests, user installs): write directly
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
