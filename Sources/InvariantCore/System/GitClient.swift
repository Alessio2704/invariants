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

  /// Returns the name of the remote default branch (e.g. "main" from refs/remotes/origin/HEAD) if available.
  public func detectRemoteTrunk(repoRoot: URL) async -> String? {
    guard
      let out = try? await runner.run(
        executableURL: SubprocessRunner.gitURL,
        arguments: ["-C", repoRoot.path, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
        workingDirectory: repoRoot
      ), out.exitCode == 0
    else {
      return nil
    }
    let trimmed = out.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let parts = trimmed.split(separator: "/")
    return parts.count >= 2 ? String(parts.dropFirst().joined(separator: "/")) : trimmed
  }

  /// Returns the current active branch name.
  public func currentBranch(repoRoot: URL) async -> String? {
    guard
      let out = try? await runner.run(
        executableURL: SubprocessRunner.gitURL,
        arguments: ["-C", repoRoot.path, "branch", "--show-current"],
        workingDirectory: repoRoot
      ), out.exitCode == 0
    else {
      return nil
    }
    let trimmed = out.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Discovers all available branches in the repository, prioritizing remote trunk and canonical branches first.
  public func discoverBranches(repoRoot: URL) async -> [String] {
    var branches: [String] = []

    if let out = try? await runner.run(
      executableURL: SubprocessRunner.gitURL,
      arguments: ["-C", repoRoot.path, "for-each-ref", "--format=%(refname:short)", "refs/heads/"],
      workingDirectory: repoRoot
    ), out.exitCode == 0 {
      branches = out.stdoutString
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }

    if branches.isEmpty {
      if let curr = await currentBranch(repoRoot: repoRoot) {
        branches = [curr]
      } else {
        branches = ["main"]
      }
    }

    // Sort order: remote trunk first, or 'main' first, or 'master' first
    let remoteTrunk = await detectRemoteTrunk(repoRoot: repoRoot)
    var sorted = branches
    if let remoteTrunk, let idx = sorted.firstIndex(of: remoteTrunk) {
      let trunk = sorted.remove(at: idx)
      sorted.insert(trunk, at: 0)
    } else if let mainIdx = sorted.firstIndex(of: "main") {
      let main = sorted.remove(at: mainIdx)
      sorted.insert(main, at: 0)
    } else if let legacyTrunkIdx = sorted.firstIndex(of: "master") {
      let legacyTrunk = sorted.remove(at: legacyTrunkIdx)
      sorted.insert(legacyTrunk, at: 0)
    }

    return sorted
  }

  /// Detects the repository's default trunk branch using discovered branches.
  public func detectDefaultBranch(repoRoot: URL) async -> String {
    let branches = await discoverBranches(repoRoot: repoRoot)
    return branches.first ?? "main"
  }
}
