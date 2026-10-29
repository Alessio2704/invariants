package import Core
package import Foundation

package enum RuleScaffoldError: LocalizedError, Sendable {
  case invalidRuleId(String)
  case ruleAlreadyExists(String)
  case invalidTarget(String)
  case noTargetsSpecified
  case notInitialized
  case noConfiguredLanguages
  case targetNotConfigured(TargetLanguage, configured: [TargetLanguage])

  package var errorDescription: String? {
    switch self {
    case .invalidRuleId(let id):
      return "Invalid rule ID '\(id)'. Rule IDs must match '^[a-z0-9]+(-[a-z0-9]+)*$' "
        + "and contain no path traversal characters."
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
    targetUnits: [TargetLanguage: [String]] = [:],
    in repoRoot: URL
  ) throws {
    // SEC-07a: Validate ruleId against schema pattern to prevent path traversal
    let idPattern = #"^[a-z0-9]+(-[a-z0-9]+)*$"#
    guard id.range(of: idPattern, options: .regularExpression) != nil else {
      throw RuleScaffoldError.invalidRuleId(id)
    }

    let rulesDir = repoRoot.appendingPathComponent("invariants/rules").standardizedFileURL
    let ruleDir = rulesDir.appendingPathComponent(id).standardizedFileURL
    guard ruleDir.path.hasPrefix(rulesDir.path + "/") else {
      throw RuleScaffoldError.invalidRuleId(id)
    }

    let fm = FileManager.default

    guard !fm.fileExists(atPath: ruleDir.path) else {
      throw RuleScaffoldError.ruleAlreadyExists(ruleDir.path)
    }

    try fm.createDirectory(at: ruleDir, withIntermediateDirectories: true)

    // 1. Generate manifest.json with unit-scoped targets
    var scopeDict: [String: Any] = [:]
    for t in targets {
      let units = (targetUnits[t]?.isEmpty == false) ? (targetUnits[t] ?? ["main"]) : ["main"]
      let defaultInclude = (t == .swift) ? ["**/*.swift"] : ["**/*.ts"]
      var unitScopes: [String: Any] = [:]
      for unit in units {
        unitScopes[unit] = ["include": defaultInclude]
      }
      scopeDict[t.rawValue] = unitScopes
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
      }

      let units = (targetUnits[t]?.isEmpty == false) ? (targetUnits[t] ?? ["main"]) : ["main"]
      if units.count > 1 {
        // Multi-unit: scaffold folder fixtures should_pass/<lang>/case1/<unit>/...
        let passCaseDir = passDir.appendingPathComponent("case1")
        let failCaseDir = failDir.appendingPathComponent("case1")
        for unit in units {
          let unitPassDir = passCaseDir.appendingPathComponent(unit)
          let unitFailDir = failCaseDir.appendingPathComponent(unit)
          try fm.createDirectory(at: unitPassDir, withIntermediateDirectories: true)
          try fm.createDirectory(at: unitFailDir, withIntermediateDirectories: true)
          if t == .swift {
            let passCase = "// Legitimate pattern for unit '\(unit)'\n"
            try passCase.data(using: .utf8)?.write(to: unitPassDir.appendingPathComponent("Code.swift"))
            let failCase = """
              // Violating pattern for unit '\(unit)'
              // expect: SAMPLE-01
              let x = "violation"
              """
            try failCase.data(using: .utf8)?.write(to: unitFailDir.appendingPathComponent("Code.swift"))
          } else {
            let passCase = "// Legitimate pattern for unit '\(unit)'\n"
            try passCase.data(using: .utf8)?.write(to: unitPassDir.appendingPathComponent("code.ts"))
            let failCase = """
              // Violating pattern for unit '\(unit)'
              // expect: SAMPLE-01
              const x = "violation";
              """
            try failCase.data(using: .utf8)?.write(to: unitFailDir.appendingPathComponent("code.ts"))
          }
        }
      } else {
        // Single unit: flat files
        if t == .swift {
          let passCase = "// Legitimate pattern\n"
          try passCase.data(using: .utf8)?.write(to: passDir.appendingPathComponent("case1.swift"))
          let failCase = """
            // Violating pattern
            // expect: SAMPLE-01
            let x = "violation"
            """
          try failCase.data(using: .utf8)?.write(to: failDir.appendingPathComponent("case1.swift"))
        } else {
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
}
