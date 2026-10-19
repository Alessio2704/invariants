public import Foundation

/// Git client wrapping `/usr/bin/git`.
public enum GitClient: Sendable {
  /// Computes the git tree hash of a directory using a temporary index file.
  public static func computeTreeHash(
    directoryRelativePath: String,
    tempIndexURL: URL
  ) async throws(SystemError) -> String {
    let repoRoot = RepoLocator.current
    // Step 1: Add directory contents to temporary index
    let addOutput = try await SubprocessRunner.run(
      binary: .git,
      arguments: ["-C", repoRoot.path, "add", "-A", directoryRelativePath],
      workingDirectory: repoRoot,
      environment: ["GIT_INDEX_FILE": tempIndexURL.path]
    )
    guard addOutput.exitCode == 0 else {
      throw SystemError.processFailed(
        executable: SystemBinary.git.path,
        arguments: ["add", "-A", directoryRelativePath],
        exitCode: addOutput.exitCode,
        stderr: addOutput.stderrString
      )
    }

    // Step 2: Write tree for prefix
    let writeOutput = try await SubprocessRunner.run(
      binary: .git,
      arguments: ["-C", repoRoot.path, "write-tree", "--prefix=\(directoryRelativePath)"],
      workingDirectory: repoRoot,
      environment: ["GIT_INDEX_FILE": tempIndexURL.path]
    )
    guard writeOutput.exitCode == 0 else {
      throw SystemError.processFailed(
        executable: SystemBinary.git.path,
        arguments: ["write-tree", "--prefix=\(directoryRelativePath)"],
        exitCode: writeOutput.exitCode,
        stderr: writeOutput.stderrString
      )
    }

    let hash = writeOutput.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    return hash
  }

  /// Extracts a tree hash into destination directory using `git archive | tar -x`.
  public static func archiveExtract(
    treeHash: String,
    destinationURL: URL
  ) async throws(SystemError) {
    let repoRoot = RepoLocator.current
    let archiveOutput = try await SubprocessRunner.run(
      binary: .git,
      arguments: ["-C", repoRoot.path, "archive", treeHash],
      workingDirectory: repoRoot
    )
    guard archiveOutput.exitCode == 0 else {
      throw SystemError.processFailed(
        executable: SystemBinary.git.path,
        arguments: ["archive", treeHash],
        exitCode: archiveOutput.exitCode,
        stderr: archiveOutput.stderrString
      )
    }

    // Extract tar using SystemBinary.tar
    let tarOutput = try await SubprocessRunner.run(
      binary: .tar,
      arguments: ["-x", "-C", destinationURL.path],
      workingDirectory: destinationURL,
      stdinData: archiveOutput.stdoutData
    )
    guard tarOutput.exitCode == 0 else {
      throw SystemError.processFailed(
        executable: SystemBinary.tar.path,
        arguments: ["-x", "-C", destinationURL.path],
        exitCode: tarOutput.exitCode,
        stderr: tarOutput.stderrString
      )
    }
  }

  /// Lists all commit hashes touching a specific file in the current ancestry.
  public static func commitHistoryTouching(
    relativePath: String
  ) async throws(SystemError) -> [String] {
    let repoRoot = RepoLocator.current
    let output = try await SubprocessRunner.run(
      binary: .git,
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
  public static func showFile(
    commit: String,
    relativePath: String
  ) async throws(SystemError) -> String {
    let repoRoot = RepoLocator.current
    let output = try await SubprocessRunner.run(
      binary: .git,
      arguments: ["-C", repoRoot.path, "show", "\(commit):\(relativePath)"],
      workingDirectory: repoRoot
    )
    guard output.exitCode == 0 else {
      throw SystemError.processFailed(
        executable: SystemBinary.git.path,
        arguments: ["show", "\(commit):\(relativePath)"],
        exitCode: output.exitCode,
        stderr: output.stderrString
      )
    }
    return output.stdoutString
  }

  /// Checks if `ancestor` is an ancestor of `descendant` (i.e. fast-forward).
  public static func isAncestor(
    ancestor: String,
    descendant: String
  ) async throws(SystemError) -> Bool {
    let repoRoot = RepoLocator.current
    let output = try await SubprocessRunner.run(
      binary: .git,
      arguments: ["-C", repoRoot.path, "merge-base", "--is-ancestor", ancestor, descendant],
      workingDirectory: repoRoot
    )
    return output.exitCode == 0
  }

  /// Stages files and commits them.
  public static func commit(
    paths: [String],
    message: String
  ) async throws(SystemError) {
    let repoRoot = RepoLocator.current
    var addArgs = ["-C", repoRoot.path, "add"]
    addArgs.append(contentsOf: paths)
    let addOutput = try await SubprocessRunner.run(
      binary: .git,
      arguments: addArgs,
      workingDirectory: repoRoot
    )
    guard addOutput.exitCode == 0 else {
      throw SystemError.processFailed(
        executable: SystemBinary.git.path,
        arguments: addArgs,
        exitCode: addOutput.exitCode,
        stderr: addOutput.stderrString
      )
    }

    let commitOutput = try await SubprocessRunner.run(
      binary: .git,
      arguments: ["-C", repoRoot.path, "commit", "-m", message],
      workingDirectory: repoRoot
    )
    guard commitOutput.exitCode == 0 else {
      throw SystemError.processFailed(
        executable: SystemBinary.git.path,
        arguments: ["commit", "-m", message],
        exitCode: commitOutput.exitCode,
        stderr: commitOutput.stderrString
      )
    }
  }

  /// Returns the name of the remote default branch (e.g. "main" from refs/remotes/origin/HEAD) if available.
  public static func detectRemoteTrunk() async -> String? {
    let repoRoot = RepoLocator.current
    guard
      let out = try? await SubprocessRunner.run(
        binary: .git,
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
  public static func currentBranch() async -> String? {
    let repoRoot = RepoLocator.current
    guard
      let out = try? await SubprocessRunner.run(
        binary: .git,
        arguments: ["-C", repoRoot.path, "branch", "--show-current"],
        workingDirectory: repoRoot
      ), out.exitCode == 0
    else {
      return nil
    }
    let trimmed = out.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Discovers comprehensive repository branch information in a single concurrent pass.
  public static func discoverRepoInfo() async -> RepoInfo {
    let repoRoot = RepoLocator.current
    async let headsTask = localBranchHeads(repoRoot: repoRoot)
    async let currentTask = currentBranch()
    async let trunkTask = detectRemoteTrunk()

    let (heads, current, trunk) = await (headsTask, currentTask, trunkTask)
    var names = heads
    if names.isEmpty, let current {
      names = [current]
    }

    // Sort order: remote trunk first, or 'main' first, or 'master' first
    var sortedNames = names
    if let trunk, let idx = sortedNames.firstIndex(of: trunk) {
      let t = sortedNames.remove(at: idx)
      sortedNames.insert(t, at: 0)
    } else if let mainIdx = sortedNames.firstIndex(of: "main") {
      let main = sortedNames.remove(at: mainIdx)
      sortedNames.insert(main, at: 0)
    } else if let legacyTrunkIdx = sortedNames.firstIndex(of: "master") {
      let legacyTrunk = sortedNames.remove(at: legacyTrunkIdx)
      sortedNames.insert(legacyTrunk, at: 0)
    }

    let branchInfos = sortedNames.map { name in
      let role: BranchRole
      if name == trunk {
        role = (name == current) ? .activeTrunk : .remoteTrunk
      } else if name == current {
        role = .active
      } else if trunk == nil && name == "main" {
        role = .recommended
      } else {
        role = .standard
      }
      return BranchInfo(name: name, role: role)
    }

    let currentBranchInfo = branchInfos.first(where: \.isActive)
    let remoteTrunkInfo = branchInfos.first(where: \.isTrunk)

    return RepoInfo(currentBranch: currentBranchInfo, remoteTrunk: remoteTrunkInfo, branches: branchInfos)
  }

  /// Discovers all available branch names in the repository, prioritizing remote trunk and canonical branches first.
  public static func discoverBranches() async -> [String] {
    await discoverRepoInfo().branches.map(\.name)
  }

  private static func localBranchHeads(repoRoot: URL) async -> [String] {
    guard
      let out = try? await SubprocessRunner.run(
        binary: .git,
        arguments: ["-C", repoRoot.path, "for-each-ref", "--format=%(refname:short)", "refs/heads/"],
        workingDirectory: repoRoot
      ), out.exitCode == 0
    else {
      return []
    }
    return out.stdoutString
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
}
