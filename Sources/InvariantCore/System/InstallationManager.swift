public import Foundation

/// Manages installation, updates, and uninstallation of the Invariants engine on the host system.
public enum InstallationManager: Sendable {
  /// Creates a symbolic link, automatically elevating if the destination requires root privileges.
  public static func createSymlink(
    from sourceURL: URL,
    to destinationURL: URL,
    token: ElevationToken? = nil
  ) async throws(SystemError) {
    let parent = destinationURL.deletingLastPathComponent()

    _ = try await SubprocessRunner.run(
      binary: .mkdir,
      arguments: ["-p", parent.path],
      targetURL: destinationURL,
      checkExitCode: true,
      elevationToken: token
    )

    _ = try await SubprocessRunner.run(
      binary: .ln,
      arguments: ["-sfn", sourceURL.path, destinationURL.path],
      targetURL: destinationURL,
      checkExitCode: true,
      elevationToken: token
    )
  }

  /// Removes a file, symbolic link, or directory at the specified target URL.
  public static func removeItem(
    at targetURL: URL,
    token: ElevationToken? = nil
  ) async throws(SystemError) {
    let exists =
      FileManager.default.fileExists(atPath: targetURL.path)
      || (try? targetURL.checkResourceIsReachable()) == true
    guard exists else { return }

    _ = try await SubprocessRunner.run(
      binary: .rm,
      arguments: ["-rf", targetURL.path],
      targetURL: targetURL,
      checkExitCode: true,
      elevationToken: token
    )
  }

  /// Installs an engine version payload from a staging directory into the system environment.
  public static func installVersion(
    version: String,
    stageDir: URL,
    environment: SystemEnvironment,
    token: ElevationToken? = nil
  ) async throws(SystemError) {
    let targetVersionDir = environment.versionsDirectoryURL.appendingPathComponent(version)

    _ = try await SubprocessRunner.run(
      binary: .mkdir,
      arguments: ["-p", targetVersionDir.path],
      targetURL: environment.rootURL,
      checkExitCode: true,
      elevationToken: token
    )

    _ = try await SubprocessRunner.run(
      binary: .cp,
      arguments: ["-R", stageDir.appendingPathComponent(".").path, targetVersionDir.path],
      targetURL: environment.rootURL,
      checkExitCode: true,
      elevationToken: token
    )

    try await createSymlink(from: targetVersionDir, to: environment.currentVersionURL, token: token)

    let currentBinary = environment.currentVersionURL.appendingPathComponent("invariants")
    try await createSymlink(from: currentBinary, to: environment.binURL, token: token)

    if SubprocessRunner.requiresElevation(for: environment.rootURL) {
      _ = try? await SubprocessRunner.run(
        binary: .chown,
        arguments: ["-R", "root:wheel", environment.rootURL.path],
        targetURL: environment.rootURL,
        checkExitCode: false,
        elevationToken: token
      )

      _ = try? await SubprocessRunner.run(
        binary: .chmod,
        arguments: ["-R", "go-w", environment.rootURL.path],
        targetURL: environment.rootURL,
        checkExitCode: false,
        elevationToken: token
      )
    }
  }

  /// Completely uninstalls the invariants engine from the system environment.
  public static func uninstall(
    environment: SystemEnvironment,
    token: ElevationToken? = nil
  ) async throws(SystemError) {
    try await removeItem(at: environment.binURL, token: token)
    try await removeItem(at: environment.rootURL, token: token)
  }
}
