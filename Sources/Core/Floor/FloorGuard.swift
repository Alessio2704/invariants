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

    let lines = pushedRefsInput.split(separator: "\n").map(\.trimmed)
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

  /// Verifies that every transition of registry.lock in commit history was signed by a key
  /// authorized in the parent commit's allowed_signers, and that any uncommitted changes
  /// in the working tree are valid against HEAD's allowed_signers.
  public static func checkSignerAncestry(
    currentRegistry: Registry
  ) async throws(FloorError) {
    // 1. Walk commit history touching invariants/registry.lock
    let commits: [String]
    do {
      commits = try await GitClient.commitHistoryTouching(
        relativePath: "invariants/registry.lock"
      )
    } catch {
      throw FloorError.systemError("Failed to inspect commit history for registry.lock: \(error)")
    }

    for commit in commits {
      let parentSignersContent: String
      do {
        parentSignersContent = try await GitClient.showFile(
          commit: "\(commit)^",
          relativePath: "invariants/allowed_signers"
        )
      } catch {
        // Root commit or parent commit without allowed_signers: base of trust reached
        continue
      }

      let commitLock: String
      let commitSig: String
      do {
        commitLock = try await GitClient.showFile(
          commit: commit,
          relativePath: "invariants/registry.lock"
        )
        commitSig = try await GitClient.showFile(
          commit: commit,
          relativePath: "invariants/registry.lock.sig"
        )
      } catch {
        continue
      }

      guard let commitData = commitLock.data(using: .utf8),
        let commitReg = try? CanonicalJSON.parse(data: commitData)
      else {
        continue
      }

      let parentLock = try? await GitClient.showFile(commit: "\(commit)^", relativePath: "invariants/registry.lock")
      let parentData = parentLock?.data(using: .utf8)
      let parentReg = parentData.flatMap { try? CanonicalJSON.parse(data: $0) }
      let parentVersion = parentReg?.version ?? max(1, commitReg.version - 1)

      let isValid = try await verifySignatureAgainstSigners(
        signersContent: parentSignersContent,
        lockContent: commitLock,
        sigContent: commitSig
      )

      if !isValid {
        throw FloorError.unauthorizedSigner(
          version: commitReg.version,
          parentVersion: parentVersion
        )
      }
    }

    // 2. Check uncommitted modifications in working tree against HEAD's allowed_signers
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
      let headRegistry = try? CanonicalJSON.parse(data: headData)
    else {
      return
    }

    let lockURL = RegistryManager.registryURL()
    let sigURL = RegistryManager.signatureURL()
    let currentLockContent = try? lockURL.readUTF8()
    let currentSigContent = try? sigURL.readUTF8()
    let isWorkingTreeModified = (currentLockContent != headLock)

    if currentRegistry.version > headRegistry.version || isWorkingTreeModified {
      guard
        let headSignersContent = try? await GitClient.showFile(
          commit: "HEAD",
          relativePath: "invariants/allowed_signers"
        ),
        let currentLock = currentLockContent,
        let currentSig = currentSigContent
      else {
        return
      }

      let isValid = try await verifySignatureAgainstSigners(
        signersContent: headSignersContent,
        lockContent: currentLock,
        sigContent: currentSig
      )

      if !isValid {
        throw FloorError.unauthorizedSigner(
          version: currentRegistry.version,
          parentVersion: headRegistry.version
        )
      }
    }
  }

  private static func verifySignatureAgainstSigners(
    signersContent: String,
    lockContent: String,
    sigContent: String
  ) async throws(FloorError) -> Bool {
    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory.appendingPathComponent("ancestry_check_\(UUID().uuidString)")
    do {
      try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    } catch {
      throw FloorError.systemError("Failed to create temporary directory for ancestry check: \(error)")
    }
    defer { try? fm.removeItem(at: tmpDir) }

    let signersURL = tmpDir.appendingPathComponent("allowed_signers")
    let lockURL = tmpDir.appendingPathComponent("registry.lock")
    let sigURL = tmpDir.appendingPathComponent("registry.lock.sig")

    do {
      try signersContent.write(to: signersURL, atomically: true, encoding: .utf8)
      try lockContent.write(to: lockURL, atomically: true, encoding: .utf8)
      try sigContent.write(to: sigURL, atomically: true, encoding: .utf8)
    } catch {
      throw FloorError.systemError("Failed to write temporary files for ancestry check: \(error)")
    }

    do {
      return try await SigningClient.verify(
        allowedSignersURL: signersURL,
        identity: "*",
        namespace: "invariants",
        signatureURL: sigURL,
        fileURL: lockURL
      )
    } catch {
      return false
    }
  }
}
