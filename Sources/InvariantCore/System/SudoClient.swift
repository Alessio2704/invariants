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

  /// Writes or appends content to a file, elevating via `sudo` only if the destination requires root privileges.
  public func writePrivilegedFile(at targetURL: URL, content: String, append: Bool = false) async throws(SystemError) {
    let tmpUserFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    guard let data = content.data(using: .utf8) else {
      throw SystemError.fileIOError("Failed to encode content as UTF-8")
    }
    do {
      try data.write(to: tmpUserFile)
    } catch {
      throw SystemError.fileIOError("Failed to prepare temp staging file: \(error.localizedDescription)")
    }
    defer { try? FileManager.default.removeItem(at: tmpUserFile) }

    let parent = targetURL.deletingLastPathComponent()
    let op =
      append ? "cat '\(tmpUserFile.path)' >> '\(targetURL.path)'" : "cp '\(tmpUserFile.path)' '\(targetURL.path)'"
    let command = "mkdir -p '\(parent.path)' && \(op)"
    try await runPrivilegedOrDirect(command: command, targetURL: targetURL)
  }

  /// Creates a symbolic link, elevating via `sudo` only if the destination requires root privileges.
  public func createSymlink(from sourceURL: URL, to destinationURL: URL) async throws(SystemError) {
    let parent = destinationURL.deletingLastPathComponent()
    let command = "mkdir -p '\(parent.path)' && ln -sfn '\(sourceURL.path)' '\(destinationURL.path)'"
    try await runPrivilegedOrDirect(command: command, targetURL: destinationURL)
  }

  /// Writes the floor version for a repo to the environment's floors directory.
  public func writeFloor(repo: String, version: Int, environment: SystemEnvironment) async throws(SystemError) {
    let floorFile = environment.floorsDirectoryURL.appendingPathComponent(repo)
    try await writePrivilegedFile(at: floorFile, content: "\(version)\n")
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
      mkdir -p '\(targetVersionDir.path)' '\(environment.floorsDirectoryURL.path)'
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
