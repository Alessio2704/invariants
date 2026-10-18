import ArgumentParser
import Foundation
import InvariantCore

@main
struct InvariantsCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "invariants",
    abstract: "Architecture constraints as code, proven by fixtures and locked by Touch ID.",
    version: EngineVersion.current,
    subcommands: [
      InitCommand.self,
      ConfigCommand.self,
      StatusCommand.self,
      NewCommand.self,
      DevCommand.self,
      TestCommand.self,
      AddCommand.self,
      UpdateCommand.self,
      RemoveCommand.self,
      UpgradeCommand.self,
      CheckCommand.self,
      SelfUpdateCommand.self,
      UninstallCommand.self,
      SignersCommand.self,
      KeyCommand.self,
    ],
    defaultSubcommand: StatusCommand.self
  )
}
