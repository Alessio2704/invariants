public import Foundation

public enum FloorError: Error, Equatable, Sendable {
  case versionBelowHistory(current: Int, maxHistoryVersion: Int)
  case versionBelowRootFloor(current: Int, rootFloor: Int, repo: String)
  case nonFastForwardPush(branch: String)
  case branchDeletion(branch: String)
  case systemError(String)
}

public struct FloorGuard: Sendable {
  private let gitClient: GitClient

  public init(gitClient: GitClient = GitClient()) {
    self.gitClient = gitClient
  }

  /// Verifies that currentVersion is >= the maximum registry version in the git commit ancestry.
  public func checkHistory(repoRoot: URL, currentVersion: Int) async throws(FloorError) -> Int {
    let commits: [String]
    do {
      commits = try await gitClient.commitHistoryTouching(
        repoRoot: repoRoot,
        relativePath: "invariants/registry.lock"
      )
    } catch {
      throw FloorError.systemError("Failed to inspect commit history for registry.lock: \(error)")
    }

    var maxVersion = currentVersion
    for commit in commits {
      let content: String
      do {
        content = try await gitClient.showFile(
          repoRoot: repoRoot,
          commit: commit,
          relativePath: "invariants/registry.lock"
        )
      } catch {
        continue
      }

      guard let data = content.data(using: .utf8),
        let reg = try? CanonicalJSON.parse(data: data)
      else {
        continue
      }

      if reg.version > maxVersion {
        maxVersion = reg.version
      }
    }

    if currentVersion < maxVersion {
      throw FloorError.versionBelowHistory(current: currentVersion, maxHistoryVersion: maxVersion)
    }
    return maxVersion
  }

  public func checkRootFloor(
    repo: String,
    currentVersion: Int,
    environment: SystemEnvironment
  ) throws(FloorError) -> Int {
    let floorFile = environment.floorsDirectoryURL.appendingPathComponent(repo)
    guard FileManager.default.fileExists(atPath: floorFile.path) else {
      return currentVersion
    }

    let content: String
    do {
      content = try String(contentsOf: floorFile, encoding: .utf8)
    } catch {
      throw FloorError.systemError("Failed to read root floor file at \(floorFile.path): \(error.localizedDescription)")
    }

    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let rootFloor = Int(trimmed) else {
      throw FloorError.systemError("Invalid content in root floor file \(floorFile.path): '\(trimmed)'")
    }

    if currentVersion < rootFloor {
      throw FloorError.versionBelowRootFloor(current: currentVersion, rootFloor: rootFloor, repo: repo)
    }
    return rootFloor
  }

  /// Pre-push hook guard: Rejects force-pushes or deletions of the default branch.
  public func checkNoRewrite(
    repoRoot: URL,
    pushedRefsInput: String,
    defaultBranch: String = "main"
  ) async throws(FloorError) {
    let zeroSha = "0000000000000000000000000000000000000000"
    let targetRef = "refs/heads/\(defaultBranch)"

    let lines = pushedRefsInput.split(separator: "\n").map {
      String($0).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    for line in lines where !line.isEmpty {
      let parts = line.split(separator: " ").map { String($0) }
      guard parts.count >= 4 else { continue }
      let localRef = parts[0]
      let localSha = parts[1]
      let remoteRef = parts[2]
      let remoteSha = parts[3]

      if remoteRef == targetRef {
        // Check deletion
        if localSha == zeroSha || localRef == "(delete)" {
          throw FloorError.branchDeletion(branch: defaultBranch)
        }

        // Check non-fast-forward
        if remoteSha != zeroSha {
          let isAncestor: Bool
          do {
            isAncestor = try await gitClient.isAncestor(
              repoRoot: repoRoot,
              ancestor: remoteSha,
              descendant: localSha
            )
          } catch {
            throw FloorError.systemError("Failed to test fast-forward ancestry: \(error)")
          }

          if !isAncestor {
            throw FloorError.nonFastForwardPush(branch: defaultBranch)
          }
        }
      }
    }
  }
}
