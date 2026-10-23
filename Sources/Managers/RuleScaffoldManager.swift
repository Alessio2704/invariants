package import Core
package import Foundation

package enum RuleScaffoldError: LocalizedError, Sendable {
  case ruleAlreadyExists(String)
  case invalidTarget(String)
  case noTargetsSpecified
  case notInitialized
  case noConfiguredLanguages
  case targetNotConfigured(TargetLanguage, configured: [TargetLanguage])

  package var errorDescription: String? {
    switch self {
    case .ruleAlreadyExists(let path):
      return "Rule directory already exists at \(path)"
    case .invalidTarget(let target):
      return "Unknown target language '\(target)'. Supported: swift, ts"
    case .noTargetsSpecified:
      return "Must specify at least one target language."
    case .notInitialized:
      return "Invariants has not been initialized in this repository. Run 'invariants init' first."
    case .noConfiguredLanguages:
      return
        "No languages are configured for this repository. Run 'invariants config languages' to configure languages first."
    case .targetNotConfigured(let target, let configured):
      let names = configured.map(\.rawValue).joined(separator: ", ")
      return "Language '\(target.rawValue)' is not configured in this repository. Configured languages: \(names)."
    }
  }
}

/// Pure domain manager for scaffolding invariant rule directories and boilerplate fixtures.
/// Completely headless: contains zero terminal formatting or CLI dependencies.
package enum RuleScaffoldManager {
  /// Scaffolds a new invariant rule with manifest and target templates in the repository.
  package static func scaffoldRule(
    id: String,
    targets: [TargetLanguage],
    in repoRoot: URL
  ) throws {
    let ruleDir = repoRoot.appendingPathComponent("invariants/rules/\(id)")
    let fm = FileManager.default

    guard !fm.fileExists(atPath: ruleDir.path) else {
      throw RuleScaffoldError.ruleAlreadyExists(ruleDir.path)
    }

    try fm.createDirectory(at: ruleDir, withIntermediateDirectories: true)

    // 1. Generate manifest.json
    var scopeDict: [String: Any] = [:]
    for t in targets {
      let defaultInclude = (t == .swift) ? ["**/*.swift"] : ["**/*.ts"]
      scopeDict[t.rawValue] = ["include": defaultInclude]
    }

    let manifestObj: [String: Any] = [
      "id": id,
      "summary": "Draft invariant rule: \(id).",
      "targets": targets.map(\.rawValue),
      "scope": scopeDict,
      "codes": [
        "SAMPLE-01": "Sample violation description"
      ],
    ]
    let manifestData = try JSONSerialization.data(
      withJSONObject: manifestObj, options: [.prettyPrinted, .sortedKeys])
    try manifestData.write(to: ruleDir.appendingPathComponent("manifest.json"), options: .atomic)

    // 2. Generate target files and fixture folders
    for t in targets {
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
  }
}
