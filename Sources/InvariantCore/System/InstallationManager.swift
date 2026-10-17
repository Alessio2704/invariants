public import Foundation

/// Manages installation, updates, and uninstallation of the Invariants engine on the host system.
public struct InstallationManager: Sendable {
  public let sudoClient: SudoClient

  public init(sudoClient: SudoClient = SudoClient()) {
    self.sudoClient = sudoClient
  }

  /// Installs an engine version payload from a staging directory into the system environment.
  public func installVersion(
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
    _ = try await sudoClient.runPrivileged(command: copyCommand, targetURL: environment.rootURL)

    try await sudoClient.createSymlink(from: targetVersionDir, to: environment.currentVersionURL)

    let currentBinary = environment.currentVersionURL.appendingPathComponent("invariants")
    try await sudoClient.createSymlink(from: currentBinary, to: environment.binURL)

    let permsCommand = """
      chown -R root:wheel '\(environment.rootURL.path)' 2>/dev/null || true
      chmod -R go-w '\(environment.rootURL.path)' 2>/dev/null || true
      """
    _ = try await sudoClient.runPrivileged(command: permsCommand, targetURL: environment.rootURL)
  }

  /// Completely uninstalls the invariants engine from the system environment.
  public func uninstall(environment: SystemEnvironment) async throws(SystemError) {
    try await sudoClient.removeItem(at: environment.binURL)
    try await sudoClient.removeItem(at: environment.rootURL)
  }
}
