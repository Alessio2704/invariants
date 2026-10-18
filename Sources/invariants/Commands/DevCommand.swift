import ArgumentParser
import Core
import Foundation

struct DevCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "dev",
    abstract: "Scaffold an autocompletion development workspace in invariants/.dev/."
  )

  func run() async throws {
    let repoRoot = try RepoLocator.discover()
    try RepoLocator.withRepoRoot(repoRoot) {
      let devDir = RepoLocator.current.appendingPathComponent(SystemPaths.devWorkspaceSubpath)
      let fm = FileManager.default
      try fm.createDirectory(at: devDir, withIntermediateDirectories: true)

      let env = SystemEnvironment.standard
      for language in SupportedLanguage.allCases {
        let files = language.spec.devWorkspaceFiles(repoRootURL: RepoLocator.current, environment: env)
        for file in files {
          let fileURL = devDir.appendingPathComponent(file.relativePath)
          let parentDir = fileURL.deletingLastPathComponent()
          if !fm.fileExists(atPath: parentDir.path) {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
          }
          try file.content.data(using: .utf8)?.write(to: fileURL, options: .atomic)
        }
      }

      print("✓ Created autocompletion workspace in invariants/.dev/")
      print("Open this folder in Xcode or VSCode for rule authoring autocomplete.")
    }
  }
}
