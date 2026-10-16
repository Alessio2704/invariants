import Foundation
import PackagePlugin

@main
struct VersionPlugin: BuildToolPlugin {
  func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
    let outputFile = context.pluginWorkDirectoryURL.appendingPathComponent("EngineVersion.generated.swift")
    let tool = try context.tool(named: "VersionGenTool")
    let gitHead = context.package.directoryURL.appendingPathComponent(".git/HEAD")

    var inputFiles: [URL] = []
    if FileManager.default.fileExists(atPath: gitHead.path) {
      inputFiles.append(gitHead)
    }

    return [
      .buildCommand(
        displayName: "Generating EngineVersion from Git",
        executable: tool.url,
        arguments: [outputFile.path, context.package.directoryURL.path],
        environment: [:],
        inputFiles: inputFiles,
        outputFiles: [outputFile]
      )
    ]
  }
}
