import Foundation

public enum RuleStatusKind: String, Sendable, Codable {
  case passed
  case violations
  case modified
  case draft
  case broken
  case missing
}

public struct RuleReportItem: Sendable, Codable, Equatable {
  public let ruleId: String
  public let statusKind: RuleStatusKind
  public let message: String?
  public let violations: [ReportedViolation]
  public let signedHash: String?
  public let currentHash: String?
  public let draftPassedFixtures: Int?
  public let draftTotalFixtures: Int?

  public init(
    ruleId: String,
    statusKind: RuleStatusKind,
    message: String? = nil,
    violations: [ReportedViolation] = [],
    signedHash: String? = nil,
    currentHash: String? = nil,
    draftPassedFixtures: Int? = nil,
    draftTotalFixtures: Int? = nil
  ) {
    self.ruleId = ruleId
    self.statusKind = statusKind
    self.message = message
    self.violations = violations
    self.signedHash = signedHash
    self.currentHash = currentHash
    self.draftPassedFixtures = draftPassedFixtures
    self.draftTotalFixtures = draftTotalFixtures
  }
}

public struct CheckReport: Sendable, Codable, Equatable {
  public let registryVersion: Int
  public let engineVersion: String
  public let rules: [RuleReportItem]
  public let isShallowRepository: Bool

  public var totalViolations: Int {
    rules.reduce(0) { $0 + $1.violations.count }
  }

  public init(
    registryVersion: Int,
    rules: [RuleReportItem],
    isShallowRepository: Bool = false
  ) {
    self.registryVersion = registryVersion
    self.engineVersion = EngineVersion.current
    self.rules = rules
    self.isShallowRepository = isShallowRepository
  }

  public var hasProblems: Bool {
    rules.contains { $0.statusKind != .passed && $0.statusKind != .draft }
  }
}

public enum ReportFormatter {
  public static func formatText(_ report: CheckReport) -> String {
    var lines: [String] = []

    let problemRules = report.rules.filter { $0.statusKind != .passed && $0.statusKind != .draft }
    if problemRules.isEmpty {
      lines.append(
        "✓ invariants check — all active rules passed (registry v\(report.registryVersion), engine \(report.engineVersion))\n"
      )
    } else {
      let regVer = "registry v\(report.registryVersion)"
      let engVer = "engine \(report.engineVersion)"
      let problemCount = max(report.totalViolations, problemRules.count)
      let problems =
        "\(problemCount) problem" + (problemCount == 1 ? "" : "s") + " in \(problemRules.count) rule"
        + (problemRules.count == 1 ? "" : "s")
      lines.append(
        "✗ invariants check — \(problems) (\(regVer), \(engVer))\n"
      )
    }

    for item in report.rules {
      switch item.statusKind {
      case .passed:
        lines.append("\(item.ruleId)  ✓ passed")
      case .violations:
        let countStr = "\(item.violations.count) violation" + (item.violations.count == 1 ? "" : "s")
        lines.append("\(item.ruleId)  ✗ \(countStr)")
        for v in item.violations {
          lines.append("  \(v.code)  \(v.file):\(v.line):\(v.column)")
          lines.append("    \(v.message)")
          if !v.fix.isEmpty {
            lines.append("    fix: \(v.fix)")
          }
        }
      case .modified:
        let sH = item.signedHash?.prefix(6) ?? ""
        let cH = item.currentHash?.prefix(6) ?? ""
        lines.append("\(item.ruleId)  ✎ modified since signed (\(sH) → \(cH))")
        lines.append("    signed version enforced; run `invariants rule update \(item.ruleId)`")
      case .draft:
        let passed = item.draftPassedFixtures ?? 0
        let total = item.draftTotalFixtures ?? 0
        lines.append("○ \(item.ruleId)  draft — \(passed)/\(total) fixtures pass")
      case .broken:
        lines.append("\(item.ruleId)  ✗ RULE BROKEN")
        if let msg = item.message {
          lines.append("    \(msg)")
        }
      case .missing:
        lines.append("\(item.ruleId)  ✗ missing on disk")
      }
      lines.append("")
    }

    return lines.joined(separator: "\n").trimmed + "\n"
  }

  public static func formatJSON(_ report: CheckReport) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(report),
      let str = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return str + "\n"
  }
}
