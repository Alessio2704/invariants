public import Foundation

/// Manages installation, updates, and uninstallation of the Invariants engine on the host system.
public enum InstallationManager: Sendable {
  /// Creates a symbolic link, automatically elevating if the destination requires root privileges.
  public static func createSymlink(from sourceURL: URL, to destinationURL: URL) async throws(SystemError) {
    let parent = destinationURL.deletingLastPathComponent()
    let command = "mkdir -p '\(parent.path)' && ln -sfn '\(sourceURL.path)' '\(destinationURL.path)'"
    _ = try await SubprocessRunner.runShell(command, targetURL: destinationURL, checkExitCode: true)
  }

  /// Removes a file, symbolic link, or directory at the specified target URL.
  public static func removeItem(at targetURL: URL) async throws(SystemError) {
    let exists =
      FileManager.default.fileExists(atPath: targetURL.path)
      || (try? targetURL.checkResourceIsReachable()) == true
    guard exists else { return }

    let command = "rm -rf '\(targetURL.path)'"
    _ = try await SubprocessRunner.runShell(command, targetURL: targetURL, checkExitCode: true)
  }

  /// Installs an engine version payload from a staging directory into the system environment.
  public static func installVersion(
    version: String,
    stageDir: URL,
    environment: SystemEnvironment
  ) async throws(SystemError) {
    let targetVersionDir = environment.versionsDirectoryURL.appendingPathComponent(version)
    let copyCommand = """
      set -e
      mkdir -p '\(targetVersionDir.path)'
      cp -R '\(stageDir.path)/.' '\(targetVersionDir.path)/'
      """
    _ = try await SubprocessRunner.runShell(copyCommand, targetURL: environment.rootURL, checkExitCode: true)

    try await createSymlink(from: targetVersionDir, to: environment.currentVersionURL)

    let currentBinary = environment.currentVersionURL.appendingPathComponent("invariants")
    try await createSymlink(from: currentBinary, to: environment.binURL)

    let permsCommand = """
      chown -R root:wheel '\(environment.rootURL.path)' 2>/dev/null || true
      chmod -R go-w '\(environment.rootURL.path)' 2>/dev/null || true
      """
    _ = try await SubprocessRunner.runShell(permsCommand, targetURL: environment.rootURL, checkExitCode: true)
  }

  /// Completely uninstalls the invariants engine from the system environment.
  public static func uninstall(environment: SystemEnvironment) async throws(SystemError) {
    try await removeItem(at: environment.binURL)
    try await removeItem(at: environment.rootURL)
  }
}
