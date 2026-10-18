import Foundation

public enum FloorError: Error, Equatable, Sendable {
  case versionBelowHistory(current: Int, maxHistoryVersion: Int)
  case nonFastForwardPush(branch: String)
  case branchDeletion(branch: String)
  case unauthorizedSigner(version: Int, parentVersion: Int)
  case systemError(String)
}

public enum FloorGuard: Sendable {
  /// Verifies that currentVersion is >= the maximum registry version in the git commit ancestry.
  public static func checkHistory(currentVersion: Int) async throws(FloorError) -> Int {
    let commits: [String]
    do {
      commits = try await GitClient.commitHistoryTouching(
        relativePath: "invariants/registry.lock"
      )
    } catch {
      throw FloorError.systemError("Failed to inspect commit history for registry.lock: \(error)")
    }

    var maxVersion = currentVersion
    for commit in commits {
      let content: String
      do {
        content = try await GitClient.showFile(
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

  /// Pre-push hook guard: Rejects force-pushes or deletions of the default branch.
  public static func checkNoRewrite(
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
            isAncestor = try await GitClient.isAncestor(
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

  /// Verifies that if registry.lock or allowed_signers was changed from HEAD,
  /// the new signature is valid against the parent commit's allowed_signers.
  public static func checkSignerAncestry(
    currentRegistry: Registry
  ) async throws(FloorError) {
    let lockURL = RegistryManager.registryURL()
    let sigURL = RegistryManager.signatureURL()
    let headLock: String
    do {
      headLock = try await GitClient.showFile(
        commit: "HEAD",
        relativePath: "invariants/registry.lock"
      )
    } catch {
      // No HEAD commit yet (initial repo setup), nothing to verify against ancestor.
      return
    }

    guard let headData = headLock.data(using: .utf8),
      let parentRegistry = try? CanonicalJSON.parse(data: headData)
    else {
      return
    }

    let isWorkingTreeRegistryModified: Bool
    do {
      let currentLockContent = (try? String(contentsOf: lockURL, encoding: .utf8)) ?? ""
      isWorkingTreeRegistryModified = (headLock != currentLockContent)
    }

    if currentRegistry.version > parentRegistry.version || isWorkingTreeRegistryModified {
      let parentSignersContent: String
      do {
        parentSignersContent = try await GitClient.showFile(
          commit: "HEAD",
          relativePath: "invariants/allowed_signers"
        )
      } catch {
        return
      }

      let fm = FileManager.default
      let tmpDir = fm.temporaryDirectory.appendingPathComponent("parent_signers_\(UUID().uuidString)")
      try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
      defer { try? fm.removeItem(at: tmpDir) }

      let parentSignersURL = tmpDir.appendingPathComponent("allowed_signers")
      guard (try? parentSignersContent.write(to: parentSignersURL, atomically: true, encoding: .utf8)) != nil else {
        return
      }

      let isValid: Bool
      do {
        isValid = try await SigningClient.verify(
          allowedSignersURL: parentSignersURL,
          identity: "*",
          namespace: "invariants",
          signatureURL: sigURL,
          fileURL: lockURL
        )
      } catch {
        throw FloorError.unauthorizedSigner(version: currentRegistry.version, parentVersion: parentRegistry.version)
      }

      if !isValid {
        throw FloorError.unauthorizedSigner(version: currentRegistry.version, parentVersion: parentRegistry.version)
      }
    }
  }
}
