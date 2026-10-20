import Foundation
import Testing

@testable import Core
@testable import Workflows

@Suite("Init Workflow & Error Handling Tests", .tags(.scenario))
struct InitWorkflowTests {

  @Test("InitWorkflowError descriptions are clear and informative")
  func errorDescriptions() {
    let err1 = InitWorkflowError.noSigningKey
    #expect(err1.errorDescription?.contains("No signing key selected") == true)

    let err2 = InitWorkflowError.noLanguagesConfigured
    #expect(err2.errorDescription?.contains("at least one supported language must be configured") == true)

    let err3 = InitWorkflowError.noBranchesFound
    #expect(err3.errorDescription?.contains("no git branches found") == true)
  }

  @Test("InitWorkflow throws noSigningKey when key cannot be resolved")
  func throwsNoSigningKey() async throws {
    let repo = try await TestRepo()
    await repo.run {
      await #expect(throws: InitWorkflowError.self) {
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

  @Test("InitWorkflow throws noLanguagesConfigured when language list is empty and no source files exist")
  func throwsNoLanguagesConfigured() async throws {
    let repo = try await TestRepo()
    await repo.run {
      await #expect(throws: InitWorkflowError.self) {
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

      let reg = try await RegistryManager.loadAndVerify(
        installedEngineVersion: EngineVersion.current
      )
      #expect(reg.version == 1)
      #expect(reg.defaultBranch == "main")
      #expect(reg.languages[SwiftLanguage.self] != nil)
    }
  }
}
