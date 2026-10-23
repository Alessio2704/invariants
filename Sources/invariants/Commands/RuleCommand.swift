import ArgumentParser
import Core
import Foundation
import Terminal
import Workflows

struct RuleCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "rule",
    abstract: "Manage invariant rules (scaffold, test, add, update, remove).",
    subcommands: [
      New.self,
      Test.self,
      Add.self,
      Update.self,
      Remove.self,
    ]
  )

  struct New: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "new",
      abstract: "Scaffold a new draft invariant rule."
    )

    @Argument(help: "The unique identifier of the rule (e.g. no-raw-text).")
    var id: String

    func run() async throws {
      do {
        let repoRoot = try RepoLocator.discover()
        try RepoLocator.withRepoRoot(repoRoot) {
          try NewRuleWorkflow.execute(id: id)
        }
      } catch {
        Terminal.error(error.localizedDescription)
        throw ExitCode(1)
      }
    }
  }

  struct Test: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "test",
      abstract: "Execute fixtures for a rule from the working tree."
    )

    @Argument(help: "The rule ID to test.")
    var id: String

    func run() async throws {
      do {
        let repoRoot = try RepoLocator.discover()
        try await RepoLocator.withRepoRoot(repoRoot) {
          let passed = try await TestRuleWorkflow.execute(ruleId: id)
          if !passed {
            throw ExitCode(1)
          }
        }
      } catch let exitCode as ExitCode {
        throw exitCode
      } catch {
        Terminal.error(error.localizedDescription)
        throw ExitCode(1)
      }
    }
  }

  struct Add: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "add",
      abstract: "Lock and activate a draft rule into the signed registry."
    )

    @Argument(help: "The rule ID to add.")
    var id: String

    @OptionGroup
    var signing: SigningOptions

    func run() async throws {
      do {
        let repoRoot = try RepoLocator.discover()
        try await RepoLocator.withRepoRoot(repoRoot) {
          try await AddRuleWorkflow.execute(ruleId: id, keyPath: signing.key)
        }
      } catch {
        Terminal.error(error.localizedDescription)
        throw ExitCode(1)
      }
    }
  }

  struct Update: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "update",
      abstract: "Update an active invariant rule with weakening detection and signature locking."
    )

    @Argument(help: "The rule ID to update.")
    var id: String

    @OptionGroup
    var signing: SigningOptions

    @Option(name: .long, help: "Confirm update by providing the exact rule ID when weakening is detected.")
    var confirmId: String?

    @Flag(name: .long, help: "Confirm update even if red-flag weakening is detected.")
    var confirm: Bool = false

    func run() async throws {
      do {
        let repoRoot = try RepoLocator.discover()
        try await RepoLocator.withRepoRoot(repoRoot) {
          try await UpdateRuleWorkflow.execute(
            input: .init(
              id: id,
              keyPath: signing.key,
              confirmId: confirmId,
              confirm: confirm
            )
          )
        }
      } catch {
        Terminal.error(error.localizedDescription)
        throw ExitCode(1)
      }
    }
  }

  struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "remove",
      abstract: "Deactivate an invariant rule and remove it from the signed registry."
    )

    @Argument(help: "The rule ID to remove.")
    var id: String

    @Flag(name: .long, help: "Delete the rule directory from disk instead of keeping it as a draft.")
    var delete: Bool = false

    @OptionGroup
    var signing: SigningOptions

    func run() async throws {
      do {
        let repoRoot = try RepoLocator.discover()
        try await RepoLocator.withRepoRoot(repoRoot) {
          try await RemoveRuleWorkflow.execute(ruleId: id, deleteFromDisk: delete, keyPath: signing.key)
        }
      } catch {
        Terminal.error(error.localizedDescription)
        throw ExitCode(1)
      }
    }
  }
}
