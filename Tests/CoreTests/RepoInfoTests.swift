import Foundation
import Testing

@testable import Core

@Suite("Git Branch & Repository Models", .tags(.unit))
struct RepoInfoTests {
  @Test("GitClient.BranchRole annotations and mutual exclusivity")
  func branchRoles() {
    #expect(GitClient.BranchRole.activeTrunk.annotation == "remote trunk, current")
    #expect(GitClient.BranchRole.remoteTrunk.annotation == "remote trunk")
    #expect(GitClient.BranchRole.active.annotation == "current")
    #expect(GitClient.BranchRole.recommended.annotation == "recommended")
    #expect(GitClient.BranchRole.standard.annotation == nil)
    #expect(GitClient.BranchRole.allCases.count == 5)
  }

  @Test("GitClient.BranchInfo computed predicates and annotations")
  func branchInfoPredicates() {
    let activeTrunk = GitClient.BranchInfo(name: "main", role: .activeTrunk)
    #expect(activeTrunk.isActive)
    #expect(activeTrunk.isTrunk)
    #expect(!activeTrunk.isRecommended)
    #expect(activeTrunk.annotation == "remote trunk, current")
    #expect(activeTrunk.id == "main")

    let remoteTrunk = GitClient.BranchInfo(name: "main", role: .remoteTrunk)
    #expect(!remoteTrunk.isActive)
    #expect(remoteTrunk.isTrunk)
    #expect(!remoteTrunk.isRecommended)
    #expect(remoteTrunk.annotation == "remote trunk")

    let activeBranch = GitClient.BranchInfo(name: "feature", role: .active)
    #expect(activeBranch.isActive)
    #expect(!activeBranch.isTrunk)
    #expect(!activeBranch.isRecommended)
    #expect(activeBranch.annotation == "current")

    let recommendedBranch = GitClient.BranchInfo(name: "main", role: .recommended)
    #expect(!recommendedBranch.isActive)
    #expect(!recommendedBranch.isTrunk)
    #expect(recommendedBranch.isRecommended)
    #expect(recommendedBranch.annotation == "recommended")

    let standardBranch = GitClient.BranchInfo(name: "dev", role: .standard)
    #expect(!standardBranch.isActive)
    #expect(!standardBranch.isTrunk)
    #expect(!standardBranch.isRecommended)
    #expect(standardBranch.annotation == nil)
  }

  @Test("GitClient.RepoInfo derives active and trunk branches from branch collection")
  func repoInfoDerivation() {
    let trunk = GitClient.BranchInfo(name: "main", role: .remoteTrunk)
    let current = GitClient.BranchInfo(name: "feature/auth", role: .active)
    let extra = GitClient.BranchInfo(name: "staging", role: .standard)

    let repo = GitClient.RepoInfo(branches: [trunk, current, extra])

    #expect(repo.remoteTrunk == trunk)
    #expect(repo.currentBranch == current)
    #expect(repo.defaultBranch == trunk)
    #expect(repo.branches.count == 3)
  }

  @Test("GitClient.RepoInfo handles empty branches and detached HEAD")
  func repoInfoEmptyAndDetached() {
    let emptyRepo = GitClient.RepoInfo(branches: [])
    #expect(emptyRepo.currentBranch == nil)
    #expect(emptyRepo.remoteTrunk == nil)
    #expect(emptyRepo.defaultBranch == nil)

    let detached = GitClient.BranchInfo(name: "main", role: .standard)
    let detachedRepo = GitClient.RepoInfo(branches: [detached])
    #expect(detachedRepo.currentBranch == nil)
    #expect(detachedRepo.remoteTrunk == nil)
    #expect(detachedRepo.defaultBranch == detached)
  }

  @Test("GitClient.RepoInfo preserves explicit current and trunk overrides")
  func repoInfoExplicitInit() {
    let activeTrunk = GitClient.BranchInfo(name: "main", role: .activeTrunk)
    let repo = GitClient.RepoInfo(
      currentBranch: activeTrunk,
      remoteTrunk: activeTrunk,
      branches: [activeTrunk]
    )

    #expect(repo.currentBranch == activeTrunk)
    #expect(repo.remoteTrunk == activeTrunk)
    #expect(repo.defaultBranch == activeTrunk)
  }
}
