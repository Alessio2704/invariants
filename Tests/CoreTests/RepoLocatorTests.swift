import Foundation
import Testing

@testable import Core

@Suite("Repository Locator & Task-Local Context", .tags(.unit))
struct RepoLocatorTests {
  @Test("RepoLocator.hasCurrent reflects active scope")
  func hasCurrentReflection() {
    #expect(!RepoLocator.hasCurrent)

    let dummyURL = URL(fileURLWithPath: "/tmp/fake_repo")
    RepoLocator.withRepoRoot(dummyURL) {
      #expect(RepoLocator.hasCurrent)
      #expect(RepoLocator.current == dummyURL)
    }

    #expect(!RepoLocator.hasCurrent)
  }

  @Test("RepoLocator.withRepoRoot propagates across async calls and child tasks")
  func asyncPropagation() async {
    let dummyURL = URL(fileURLWithPath: "/tmp/async_repo")

    await RepoLocator.withRepoRoot(dummyURL) {
      #expect(RepoLocator.hasCurrent)
      #expect(RepoLocator.current == dummyURL)

      // Child task via Task
      let childURL = await Task {
        RepoLocator.current
      }.value
      #expect(childURL == dummyURL)

      // Child task via async let
      async let asyncChildURL: URL = {
        RepoLocator.current
      }()
      let resolved = await asyncChildURL
      #expect(resolved == dummyURL)
    }
  }

  @Test("Nested withRepoRoot correctly shadows and restores parent scope")
  func nestedScoping() {
    let parentURL = URL(fileURLWithPath: "/tmp/parent_repo")
    let childURL = URL(fileURLWithPath: "/tmp/child_repo")

    RepoLocator.withRepoRoot(parentURL) {
      #expect(RepoLocator.current == parentURL)

      RepoLocator.withRepoRoot(childURL) {
        #expect(RepoLocator.current == childURL)
      }

      #expect(RepoLocator.current == parentURL)
    }

    #expect(!RepoLocator.hasCurrent)
  }

  @Test("RepoLocator.discover detects .git boundary")
  func discoveryFromSubdirectory() throws {
    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory.appendingPathComponent("discover_test_\(UUID().uuidString)")
    let subDir = tmpDir.appendingPathComponent("Sources/App/Deep/Nested")
    try fm.createDirectory(at: subDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: tmpDir.appendingPathComponent(".git"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    let discovered = try RepoLocator.discover(from: subDir)
    #expect(discovered.standardizedFileURL.path == tmpDir.standardizedFileURL.path)
  }

  @Test("RepoLocator.discover throws repositoryNotFound when no .git exists")
  func discoverFailsOutsideRepo() {
    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory.appendingPathComponent("no_git_\(UUID().uuidString)")
    try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    #expect(throws: RepoLocatorError.notInsideGitRepository) {
      try RepoLocator.discover(from: tmpDir)
    }
  }
}
