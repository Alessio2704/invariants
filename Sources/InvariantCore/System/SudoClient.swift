public import Foundation

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

  /// Executes a shell command, automatically elevating via `sudo` if the target location requires root privileges.
  private func runPrivilegedOrDirect(command: String, targetURL: URL) async throws(SystemError) {
    let needsElevation = requiresElevation(for: targetURL)
    let executable = needsElevation ? SubprocessRunner.sudoURL : URL(fileURLWithPath: "/bin/sh")
    let arguments = needsElevation ? ["/bin/sh", "-c", command] : ["-c", command]

    let output = try await runner.run(executableURL: executable, arguments: arguments)
    guard output.exitCode == 0 else {
      throw SystemError.processFailed(
        executable: executable.path,
        arguments: arguments,
        exitCode: output.exitCode,
        stderr: output.stderrString
      )
    }
  }

  /// Creates a symbolic link, elevating via `sudo` only if the destination requires root privileges.
  public func createSymlink(from sourceURL: URL, to destinationURL: URL) async throws(SystemError) {
    let parent = destinationURL.deletingLastPathComponent()
    let command = "mkdir -p '\(parent.path)' && ln -sfn '\(sourceURL.path)' '\(destinationURL.path)'"
    try await runPrivilegedOrDirect(command: command, targetURL: destinationURL)
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
    try await runPrivilegedOrDirect(command: copyCommand, targetURL: environment.rootURL)

    try await createSymlink(from: targetVersionDir, to: environment.currentVersionURL)

    let currentBinary = environment.currentVersionURL.appendingPathComponent("invariants")
    try await createSymlink(from: currentBinary, to: environment.binURL)

    let permsCommand = """
      chown -R root:wheel '\(environment.rootURL.path)' 2>/dev/null || true
      chmod -R go-w '\(environment.rootURL.path)' 2>/dev/null || true
      """
    try await runPrivilegedOrDirect(command: permsCommand, targetURL: environment.rootURL)
  }

  /// Removes a file, symbolic link, or directory at the specified target URL.
  public func removeItem(at targetURL: URL) async throws(SystemError) {
    let exists =
      FileManager.default.fileExists(atPath: targetURL.path)
      || (try? targetURL.checkResourceIsReachable()) == true
    guard exists else { return }

    let command = "rm -rf '\(targetURL.path)'"
    try await runPrivilegedOrDirect(command: command, targetURL: targetURL)
  }

  /// Completely uninstalls the invariants engine from the system environment.
  public func uninstall(environment: SystemEnvironment) async throws(SystemError) {
    try await removeItem(at: environment.binURL)
    try await removeItem(at: environment.rootURL)
  }
}
