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

  /// Writes or appends content to a file, elevating via `sudo` if the destination requires root privileges.
  public func writePrivilegedFile(at targetURL: URL, content: String, append: Bool = false) async throws(SystemError) {
    if requiresElevation(for: targetURL) {
      let tmpUserFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      do {
        guard let data = content.data(using: .utf8) else {
          throw SystemError.fileIOError("Failed to encode content as UTF-8")
        }
        try data.write(to: tmpUserFile)
      } catch {
        throw SystemError.fileIOError("Failed to prepare temp staging file: \(error.localizedDescription)")
      }
      defer { try? FileManager.default.removeItem(at: tmpUserFile) }

      let parent = targetURL.deletingLastPathComponent()
      let op =
        append ? "cat '\(tmpUserFile.path)' >> '\(targetURL.path)'" : "cp '\(tmpUserFile.path)' '\(targetURL.path)'"
      let command = "mkdir -p '\(parent.path)' && \(op)"
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
      do {
        let parent = targetURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        guard let data = content.data(using: .utf8) else {
          throw SystemError.fileIOError("Failed to encode content as UTF-8")
        }
        if append && FileManager.default.fileExists(atPath: targetURL.path) {
          let handle = try FileHandle(forWritingTo: targetURL)
          try handle.seekToEnd()
          try handle.write(contentsOf: data)
          try handle.close()
        } else {
          try data.write(to: targetURL, options: .atomic)
        }
      } catch let error as SystemError {
        throw error
      } catch {
        throw SystemError.fileIOError("Failed to write file at \(targetURL.path): \(error.localizedDescription)")
      }
    }
  }

  /// Creates a symbolic link, elevating via `sudo` if writing to destination requires root privileges.
  public func createSymlink(from sourceURL: URL, to destinationURL: URL) async throws(SystemError) {
    if requiresElevation(for: destinationURL) {
      let parent = destinationURL.deletingLastPathComponent()
      let command = "mkdir -p '\(parent.path)' && ln -sfn '\(sourceURL.path)' '\(destinationURL.path)'"
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
      do {
        let parent = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let exists =
          FileManager.default.fileExists(atPath: destinationURL.path)
          || (try? destinationURL.checkResourceIsReachable()) == true
        if exists {
          try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.createSymbolicLink(at: destinationURL, withDestinationURL: sourceURL)
      } catch {
        throw SystemError.fileIOError(
          "Failed to create symlink from \(sourceURL.path) to \(destinationURL.path): \(error.localizedDescription)")
      }
    }
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

    if requiresElevation(for: environment.rootURL) {
      let binParent = environment.binURL.deletingLastPathComponent()
      let command = """
        set -e
        mkdir -p '\(targetVersionDir.path)' '\(environment.floorsDirectoryURL.path)' '\(binParent.path)'
        cp -R '\(stageDir.path)/.' '\(targetVersionDir.path)/'
        ln -sfn '\(targetVersionDir.path)' '\(environment.currentVersionURL.path)'
        ln -sfn '\(environment.currentVersionURL.path)/invariants' '\(environment.binURL.path)'
        chown -R root:wheel '\(environment.rootURL.path)' 2>/dev/null || true
        chmod -R go-w '\(environment.rootURL.path)' 2>/dev/null || true
        """
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
      do {
        try FileManager.default.createDirectory(at: targetVersionDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: environment.floorsDirectoryURL, withIntermediateDirectories: true)
        let items = try FileManager.default.contentsOfDirectory(atPath: stageDir.path)
        for item in items {
          let src = stageDir.appendingPathComponent(item)
          let dst = targetVersionDir.appendingPathComponent(item)
          if FileManager.default.fileExists(atPath: dst.path) {
            try FileManager.default.removeItem(at: dst)
          }
          try FileManager.default.copyItem(at: src, to: dst)
        }
        try await createSymlink(from: targetVersionDir, to: environment.currentVersionURL)
        let binaryInCurrent = environment.currentVersionURL.appendingPathComponent("invariants")
        try await createSymlink(from: binaryInCurrent, to: environment.binURL)
      } catch let error as SystemError {
        throw error
      } catch {
        throw SystemError.fileIOError("Failed to install version \(version): \(error.localizedDescription)")
      }
    }
  }

  /// Completely uninstalls the invariants engine from the system environment.
  public func uninstall(environment: SystemEnvironment) async throws(SystemError) {
    if requiresElevation(for: environment.rootURL) || requiresElevation(for: environment.binURL) {
      let command = "rm -f '\(environment.binURL.path)' && rm -rf '\(environment.rootURL.path)'"
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
      try? FileManager.default.removeItem(at: environment.binURL)
      try? FileManager.default.removeItem(at: environment.rootURL)
    }
  }
}
