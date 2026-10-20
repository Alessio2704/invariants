package import Core
package import Foundation

/// Pure domain manager for generating autocompletion development workspaces.
/// Completely headless: contains zero terminal formatting or CLI dependencies.
package enum DevWorkspaceManager {
  /// Scaffolds development workspace files for all supported languages in the repository.
  package static func generateWorkspace(
    in repoRoot: URL,
    environment: SystemEnvironment = .standard
  ) throws {
    let devDir = repoRoot.appendingPathComponent(SystemPaths.devWorkspaceSubpath)
    let fm = FileManager.default
    try fm.createDirectory(at: devDir, withIntermediateDirectories: true)

    for language in SupportedLanguage.allCases {
      let files = language.spec.devWorkspaceFiles(environment: environment)
      for file in files {
        let fileURL = devDir.appendingPathComponent(file.relativePath)
        let parentDir = fileURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: parentDir.path) {
          try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        try file.content.data(using: .utf8)?.write(to: fileURL, options: .atomic)
      }
    }
  }
}
