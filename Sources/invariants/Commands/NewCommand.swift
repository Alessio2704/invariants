import ArgumentParser
import Core
import Foundation
import Terminal

struct NewCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "new",
    abstract: "Scaffold a new draft invariant rule."
  )

  @Argument(help: "The unique identifier of the rule (e.g. no-raw-text).")
  var id: String

  @Option(name: .long, help: "Comma-separated target languages: swift, ts.")
  var targets: String = "swift"

  func run() async throws {
    do {
      let repoRoot = try RepoLocator.discover()
      try RepoLocator.withRepoRoot(repoRoot) {
        let ruleDir = RepoLocator.current.appendingPathComponent("invariants/rules/\(id)")
        let fm = FileManager.default

        guard !fm.fileExists(atPath: ruleDir.path) else {
          Terminal.error("Rule directory already exists at \(ruleDir.path)")
          throw ExitCode(1)
        }

        let targetList = targets.split(separator: ",").map(\.trimmed)
        var declaredTargets: [TargetLanguage] = []
        for t in targetList {
          guard let lang = TargetLanguage(rawValue: t) else {
            Terminal.error("Unknown target language '\(t)'. Supported: swift, ts")
            throw ExitCode(1)
          }
          declaredTargets.append(lang)
        }

        guard !declaredTargets.isEmpty else {
          Terminal.error("Must specify at least one target language.")
          throw ExitCode(1)
        }

        try fm.createDirectory(at: ruleDir, withIntermediateDirectories: true)

        // 1. Generate manifest.json
        var scopeDict: [String: Any] = [:]
        for t in declaredTargets {
          let defaultInclude = (t == .swift) ? ["**/*.swift"] : ["**/*.ts"]
          scopeDict[t.rawValue] = ["include": defaultInclude]
        }

        let manifestObj: [String: Any] = [
          "id": id,
          "summary": "Draft invariant rule: \(id).",
          "targets": declaredTargets.map { $0.rawValue },
          "scope": scopeDict,
          "codes": [
            "SAMPLE-01": "Sample violation description"
          ],
        ]
        let manifestData = try JSONSerialization.data(
          withJSONObject: manifestObj, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: ruleDir.appendingPathComponent("manifest.json"), options: .atomic)

        // 2. Generate target files and fixture folders
        for t in declaredTargets {
          let passDir = ruleDir.appendingPathComponent("should_pass/\(t.rawValue)")
          let failDir = ruleDir.appendingPathComponent("should_fail/\(t.rawValue)")
          try fm.createDirectory(at: passDir, withIntermediateDirectories: true)
          try fm.createDirectory(at: failDir, withIntermediateDirectories: true)

          if t == .swift {
            let ruleSwift = """
              import InvariantKit

              @main
              struct \(id.replacingOccurrences(of: "-", with: "_").capitalized)Rule: SwiftRule {
                  func check(_ ctx: RuleContext) throws(RuleError) -> [Violation] {
                      // Implement invariant check here
                      return []
                  }
              }
              """
            try ruleSwift.data(using: .utf8)?.write(to: ruleDir.appendingPathComponent("rule.swift"))

            let passCase = "// Legitimate pattern\n"
            try passCase.data(using: .utf8)?.write(to: passDir.appendingPathComponent("case1.swift"))

            let failCase = """
              // Violating pattern
              // expect: SAMPLE-01
              let x = "violation"
              """
            try failCase.data(using: .utf8)?.write(to: failDir.appendingPathComponent("case1.swift"))
          } else if t == .ts {
            let ruleTs = """
              import { defineRule } from "@invariants/kit";

              export default defineRule({
                check(ctx) {
                  // Implement invariant check here
                  return [];
                },
              });
              """
            try ruleTs.data(using: .utf8)?.write(to: ruleDir.appendingPathComponent("rule.ts"))

            let passCase = "// Legitimate pattern\n"
            try passCase.data(using: .utf8)?.write(to: passDir.appendingPathComponent("case1.ts"))

            let failCase = """
              // Violating pattern
              // expect: SAMPLE-01
              const x = "violation";
              """
            try failCase.data(using: .utf8)?.write(to: failDir.appendingPathComponent("case1.ts"))
          }
        }

        Terminal.success("Scaffolded draft rule '\(id)' at invariants/rules/\(id)/")
        Terminal.info("Next steps:")
        Terminal.info("  1. Write fixtures first in should_fail and should_pass (they are the spec).")
        Terminal.info("  2. Implement the check in rule.\(declaredTargets[0].rawValue).")
        Terminal.info("  3. Run 'invariants test \(id)' until green.")
        Terminal.info("  4. Run 'invariants add \(id)' to lock and activate with Touch ID.")
      }
    } catch let exitCode as ExitCode {
      throw exitCode
    } catch {
      Terminal.error(error.localizedDescription)
      throw ExitCode(1)
    }
  }
}
