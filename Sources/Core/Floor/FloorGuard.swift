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

    let lines = pushedRefsInput.split(separator: "\n").map(\.trimmed).filter { !$0.isEmpty }
    guard !lines.isEmpty else {
      throw FloorError.systemError("Pre-push hook received empty stdin refspec input. Verification aborted.")
    }

    for line in lines {
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
  @discardableResult
  public static func checkSignerAncestry(
    currentRegistry: Registry
  ) async throws(FloorError) -> Bool {
    let isShallow = await GitClient.isShallowRepository()
    // 1. Walk commit history touching invariants/registry.lock
    let commits: [String]
    do {
      commits = try await GitClient.commitHistoryTouching(
        relativePath: "invariants/registry.lock"
      )
    } catch {
      throw FloorError.systemError("Failed to inspect commit history for registry.lock: \(error)")
    }

    var trustedSignersContent: String?
    var trustedVersion: Int = 1
    var lastCommitLock: String?
    var lastCommitDate: String?

    for commit in commits.reversed() {
      let commitLock: String
      let commitSig: String
      let commitSigners: String
      do {
        commitLock = try await GitClient.showFile(
          commit: commit,
          relativePath: "invariants/registry.lock"
        )
        commitSig = try await GitClient.showFile(
          commit: commit,
          relativePath: "invariants/registry.lock.sig"
        )
        commitSigners = try await GitClient.showFile(
          commit: commit,
          relativePath: "invariants/allowed_signers"
        )
      } catch {
        throw FloorError.unauthorizedSigner(
          version: currentRegistry.version,
          parentVersion: trustedVersion
        )
      }

      guard let commitData = commitLock.data(using: .utf8),
        let commitReg = try? CanonicalJSON.parse(data: commitData)
      else {
        throw FloorError.unauthorizedSigner(
          version: currentRegistry.version,
          parentVersion: trustedVersion
        )
      }

      let signersToVerifyAgainst: String
      if let previousTrustedSigners = trustedSignersContent {
        signersToVerifyAgainst = previousTrustedSigners
      } else if let parentSigners = try? await GitClient.showFile(
        commit: "\(commit)^",
        relativePath: "invariants/allowed_signers"
      ) {
        signersToVerifyAgainst = parentSigners
      } else {
        // Root/initial commit establishing invariants/registry.lock: base of trust
        // SEC-05a: Shallow clones must not treat truncated HEAD as a trusted root commit
        if isShallow {
          throw FloorError.unauthorizedSigner(
            version: commitReg.version,
            parentVersion: trustedVersion
          )
        }
        signersToVerifyAgainst = commitSigners
      }

      let commitDate = await GitClient.commitDate(commit: commit)

      // SEC-04a: Commit timestamps must be strictly monotonic across parent -> child transitions
      // to prevent backdated commit date spoofing to revive expired keys
      if let commitDate, let previousDate = lastCommitDate {
        if commitDate < previousDate {
          throw FloorError.unauthorizedSigner(
            version: commitReg.version,
            parentVersion: trustedVersion
          )
        }
      }
      lastCommitDate = commitDate

      let isValid = try await verifySignatureAgainstSigners(
        signersContent: signersToVerifyAgainst,
        lockContent: commitLock,
        sigContent: commitSig,
        verifyTime: commitDate
      )

      if !isValid {
        throw FloorError.unauthorizedSigner(
          version: commitReg.version,
          parentVersion: trustedVersion
        )
      }

      trustedSignersContent = commitSigners
      trustedVersion = commitReg.version
      lastCommitLock = commitLock
    }

    // 2. Check uncommitted modifications in working tree against the latest verified allowed_signers
    guard let baseSigners = trustedSignersContent,
      let committedLock = lastCommitLock
    else {
      // No committed registry.lock history yet (initial repo setup), nothing to verify against ancestor.
      return isShallow
    }

    let lockURL = RegistryManager.registryURL()
    let sigURL = RegistryManager.signatureURL()
    let currentLockContent = try? lockURL.readUTF8()
    let currentSigContent = try? sigURL.readUTF8()
    let isWorkingTreeModified = (currentLockContent != committedLock)

    if currentRegistry.version > trustedVersion || isWorkingTreeModified {
      guard let currentLock = currentLockContent,
        let currentSig = currentSigContent
      else {
        throw FloorError.unauthorizedSigner(
          version: currentRegistry.version,
          parentVersion: trustedVersion
        )
      }

      let isValid = try await verifySignatureAgainstSigners(
        signersContent: baseSigners,
        lockContent: currentLock,
        sigContent: currentSig
      )

      if !isValid {
        throw FloorError.unauthorizedSigner(
          version: currentRegistry.version,
          parentVersion: trustedVersion
        )
      }
    }

    return isShallow
  }

  private static func verifySignatureAgainstSigners(
    signersContent: String,
    lockContent: String,
    sigContent: String,
    verifyTime: String? = nil
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
        fileURL: lockURL,
        verifyTime: verifyTime
      )
    } catch {
      return false
    }
  }
}
