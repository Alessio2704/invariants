public import Foundation

/// Git client wrapping `/usr/bin/git`.
public struct GitClient: Sendable {
  private let runner: SubprocessRunner

  public init(runner: SubprocessRunner = SubprocessRunner()) {
    self.runner = runner
  }

  /// Computes the git tree hash of a directory using a temporary index file.
  public func computeTreeHash(
    repoRoot: URL,
    directoryRelativePath: String,
    tempIndexURL: URL
  ) async throws(SystemError) -> String {
    // Step 1: Add directory contents to temporary index
    let addOutput = try await runner.run(
      executableURL: SubprocessRunner.gitURL,
      arguments: ["-C", repoRoot.path, "add", "-A", directoryRelativePath],
      workingDirectory: repoRoot,
      environment: ["GIT_INDEX_FILE": tempIndexURL.path]
    )
    guard addOutput.exitCode == 0 else {
      throw SystemError.processFailed(
        executable: SubprocessRunner.gitURL.path,
        arguments: ["add", "-A", directoryRelativePath],
        exitCode: addOutput.exitCode,
        stderr: addOutput.stderrString
      )
    }

    // Step 2: Write tree for prefix
    let writeOutput = try await runner.run(
      executableURL: SubprocessRunner.gitURL,
      arguments: ["-C", repoRoot.path, "write-tree", "--prefix=\(directoryRelativePath)"],
      workingDirectory: repoRoot,
      environment: ["GIT_INDEX_FILE": tempIndexURL.path]
    )
    guard writeOutput.exitCode == 0 else {
      throw SystemError.processFailed(
        executable: SubprocessRunner.gitURL.path,
        arguments: ["write-tree", "--prefix=\(directoryRelativePath)"],
        exitCode: writeOutput.exitCode,
        stderr: writeOutput.stderrString
      )
    }

    let hash = writeOutput.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    return hash
  }

  /// Extracts a tree hash into destination directory using `git archive | tar -x`.
  public func archiveExtract(repoRoot: URL, treeHash: String, destinationURL: URL) async throws(SystemError) {
    let archiveOutput = try await runner.run(
      executableURL: SubprocessRunner.gitURL,
      arguments: ["-C", repoRoot.path, "archive", treeHash],
      workingDirectory: repoRoot
    )
    guard archiveOutput.exitCode == 0 else {
      throw SystemError.processFailed(
        executable: SubprocessRunner.gitURL.path,
        arguments: ["archive", treeHash],
        exitCode: archiveOutput.exitCode,
        stderr: archiveOutput.stderrString
      )
    }

    // Extract tar using /usr/bin/tar
    let tarURL = URL(fileURLWithPath: "/usr/bin/tar")
    let tarOutput = try await runner.run(
      executableURL: tarURL,
      arguments: ["-x", "-C", destinationURL.path],
      workingDirectory: destinationURL,
      stdinData: archiveOutput.stdoutData
    )
    guard tarOutput.exitCode == 0 else {
      throw SystemError.processFailed(
        executable: tarURL.path,
        arguments: ["-x", "-C", destinationURL.path],
        exitCode: tarOutput.exitCode,
        stderr: tarOutput.stderrString
      )
    }
  }

  /// Lists all commit hashes touching a specific file in the current ancestry.
  public func commitHistoryTouching(repoRoot: URL, relativePath: String) async throws(SystemError) -> [String] {
    let output = try await runner.run(
      executableURL: SubprocessRunner.gitURL,
      arguments: ["-C", repoRoot.path, "log", "--format=%H", "--", relativePath],
      workingDirectory: repoRoot
    )
    guard output.exitCode == 0 else {
      // If repository has no commits yet, git log returns error 128
      return []
    }
    let lines = output.stdoutString.split(separator: "\n").map {
      String($0).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return lines.filter { !$0.isEmpty }
  }

  /// Reads a file's content at a given commit.
  public func showFile(repoRoot: URL, commit: String, relativePath: String) async throws(SystemError) -> String {
    let output = try await runner.run(
      executableURL: SubprocessRunner.gitURL,
      arguments: ["-C", repoRoot.path, "show", "\(commit):\(relativePath)"],
      workingDirectory: repoRoot
    )
    guard output.exitCode == 0 else {
      throw SystemError.processFailed(
        executable: SubprocessRunner.gitURL.path,
        arguments: ["show", "\(commit):\(relativePath)"],
        exitCode: output.exitCode,
        stderr: output.stderrString
      )
    }
    return output.stdoutString
  }

  /// Checks if `ancestor` is an ancestor of `descendant` (i.e. fast-forward).
  public func isAncestor(repoRoot: URL, ancestor: String, descendant: String) async throws(SystemError) -> Bool {
    let output = try await runner.run(
      executableURL: SubprocessRunner.gitURL,
      arguments: ["-C", repoRoot.path, "merge-base", "--is-ancestor", ancestor, descendant],
      workingDirectory: repoRoot
    )
    return output.exitCode == 0
  }

  /// Configures core.hooksPath.
  public func setHooksPath(repoRoot: URL, path: String) async throws(SystemError) {
    let output = try await runner.run(
      executableURL: SubprocessRunner.gitURL,
      arguments: ["-C", repoRoot.path, "config", "core.hooksPath", path],
      workingDirectory: repoRoot
    )
    guard output.exitCode == 0 else {
      throw SystemError.processFailed(
        executable: SubprocessRunner.gitURL.path,
        arguments: ["config", "core.hooksPath", path],
        exitCode: output.exitCode,
        stderr: output.stderrString
      )
    }
  }

  /// Gets core.hooksPath.
  public func getHooksPath(repoRoot: URL) async throws(SystemError) -> String? {
    let output = try await runner.run(
      executableURL: SubprocessRunner.gitURL,
      arguments: ["-C", repoRoot.path, "config", "--get", "core.hooksPath"],
      workingDirectory: repoRoot
    )
    if output.exitCode != 0 {
      return nil
    }
    let trimmed = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Stages files and commits them.
  public func commit(repoRoot: URL, paths: [String], message: String) async throws(SystemError) {
    var addArgs = ["-C", repoRoot.path, "add"]
    addArgs.append(contentsOf: paths)
    let addOutput = try await runner.run(
      executableURL: SubprocessRunner.gitURL,
      arguments: addArgs,
      workingDirectory: repoRoot
    )
    guard addOutput.exitCode == 0 else {
      throw SystemError.processFailed(
        executable: SubprocessRunner.gitURL.path,
        arguments: addArgs,
        exitCode: addOutput.exitCode,
        stderr: addOutput.stderrString
      )
    }

    let commitOutput = try await runner.run(
      executableURL: SubprocessRunner.gitURL,
      arguments: ["-C", repoRoot.path, "commit", "-m", message],
      workingDirectory: repoRoot
    )
    guard commitOutput.exitCode == 0 else {
      throw SystemError.processFailed(
        executable: SubprocessRunner.gitURL.path,
        arguments: ["commit", "-m", message],
        exitCode: commitOutput.exitCode,
        stderr: commitOutput.stderrString
      )
    }
  }

  /// Detects the active or default branch for the repository.
  public func detectDefaultBranch(repoRoot: URL) async -> String {
    // 1. Try git symbolic-ref refs/remotes/origin/HEAD
    if let out = try? await runner.run(
      executableURL: SubprocessRunner.gitURL,
      arguments: ["-C", repoRoot.path, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
      workingDirectory: repoRoot
    ), out.exitCode == 0 {
      let trimmed = out.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        let parts = trimmed.split(separator: "/")
        if parts.count >= 2 {
          return String(parts.dropFirst().joined(separator: "/"))
        }
        return trimmed
      }
    }

    // 2. Try git branch --show-current
    if let out = try? await runner.run(
      executableURL: SubprocessRunner.gitURL,
      arguments: ["-C", repoRoot.path, "branch", "--show-current"],
      workingDirectory: repoRoot
    ), out.exitCode == 0 {
      let trimmed = out.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        return trimmed
      }
    }

    // 3. Fallback to "main"
    return "main"
  }
}
