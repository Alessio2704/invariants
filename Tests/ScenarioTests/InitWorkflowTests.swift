import Foundation
import Terminal
import Testing

@testable import Core
@testable import Workflows

@Suite("Init Workflow & Error Handling Tests", .tags(.scenario))
struct InitWorkflowTests {

  @Test("InitWorkflowError descriptions are clear and informative")
  func errorDescriptions() {
    let err2 = InitWorkflowError.noLanguagesConfigured
    #expect(err2.errorDescription?.contains("at least one supported language must be configured") == true)

    let err3 = InitWorkflowError.noBranchesFound
    #expect(err3.errorDescription?.contains("no git branches found") == true)
  }

  @Test("InitWorkflow throws SigningError when key cannot be resolved")
  func throwsSigningError() async throws {
    let repo = try await TestRepo()
    await repo.run {
      await #expect(throws: SigningError.self) {
        try await InitWorkflow.execute(
          input: .init(
            branch: "main",
            languages: [.swift],
            keyPath: "/nonexistent/key/path"
          )
        )
      }
    }
  }

  @Test(
    "InitWorkflow throws TerminalPromptError when language list is empty, no source files exist, and environment is non-interactive"
  )
  func throwsNoLanguagesConfigured() async throws {
    let repo = try await TestRepo()
    await repo.run {
      await #expect(throws: TerminalPromptError.self) {
        try await InitWorkflow.execute(
          input: .init(
            branch: "main",
            languages: [],
            keyPath: repo.keyURL.path
          )
        )
      }
    }
  }

  @Test("InitWorkflow successfully initializes repository when valid input provided")
  func successfulInitialization() async throws {
    let repo = try await TestRepo()
    try FileManager.default.createDirectory(
      at: repo.repoURL.appendingPathComponent(".build/out"),
      withIntermediateDirectories: true
    )
    try await repo.run {
      try await InitWorkflow.execute(
        input: .init(
          branch: "main",
          languages: [.swift],
          keyPath: repo.keyURL.path
        )
      )

      let reg = try await RegistryManager.loadAndVerify()
      #expect(reg.version == 1)
      #expect(reg.defaultBranch == "main")
      #expect(reg.languages.contains(.swift))
    }
  }
}
