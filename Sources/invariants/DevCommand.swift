import ArgumentParser
import Foundation
import InvariantCore

struct DevCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "dev",
    abstract: "Scaffold an autocompletion development workspace in invariants/.dev/."
  )

  @Option(name: .long, help: "Explicit repository root path (used in testing).")
  var repoPath: String?

  func run() async throws {
    let repoRootURL: URL
    if let repoPath {
      repoRootURL = URL(fileURLWithPath: repoPath)
    } else if let found = CLIHelpers.findRepoRoot() {
      repoRootURL = found
    } else {
      fputs("Error: Not inside a git repository.\n", stderr)
      throw ExitCode(1)
    }

    let devDir = repoRootURL.appendingPathComponent("invariants/.dev")
    let fm = FileManager.default
    try fm.createDirectory(at: devDir, withIntermediateDirectories: true)

    let env = SystemEnvironment.standard
    let kitSwiftPath = fm.fileExists(atPath: env.kitSwiftURL.path) ? env.kitSwiftURL.path : repoRootURL.path

    let devPackage = """
      // swift-tools-version: 6.0
      import PackageDescription

      let package = Package(
          name: "InvariantsDev",
          platforms: [.macOS(.v14)],
          dependencies: [
              .package(path: "\(kitSwiftPath)")
          ],
          targets: [
              .target(
                  name: "InvariantsDev",
                  dependencies: [
                      .product(name: "InvariantKit", package: "invariants")
                  ],
                  path: "."
              )
          ]
      )
      """
    try devPackage.data(using: .utf8)?.write(to: devDir.appendingPathComponent("Package.swift"), options: .atomic)

    let devTsconfig = """
      {
        "compilerOptions": {
          "target": "ES2022",
          "module": "NodeNext",
          "moduleResolution": "NodeNext",
          "strict": true
        },
        "include": ["../rules/**/*.ts"]
      }
      """
    try devTsconfig.data(using: .utf8)?.write(to: devDir.appendingPathComponent("tsconfig.json"), options: .atomic)

    print("✓ Created autocompletion workspace in invariants/.dev/")
    print("Open this folder in Xcode or VSCode for rule authoring autocomplete.")
  }
}
