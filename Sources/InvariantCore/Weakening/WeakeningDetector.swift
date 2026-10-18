import Foundation

public enum WeakeningSeverity: String, Sendable, Equatable {
  case red
  case green
}

public struct WeakeningItem: Sendable, Equatable {
  public let severity: WeakeningSeverity
  public let category: String
  public let message: String

  public init(severity: WeakeningSeverity, category: String, message: String) {
    self.severity = severity
    self.category = category
    self.message = message
  }
}

public struct WeakeningReport: Sendable, Equatable {
  public let ruleId: String
  public let items: [WeakeningItem]

  public var hasRedFlags: Bool {
    items.contains { $0.severity == .red }
  }

  public var hasGreenFlags: Bool {
    items.contains { $0.severity == .green }
  }

  public init(ruleId: String, items: [WeakeningItem]) {
    self.ruleId = ruleId
    self.items = items
  }
}

public enum WeakeningDetector: Sendable {
  /// Analyzes mutations between an old signed rule and the new working tree rule.
  public static func detect(
    ruleId: String,
    oldManifest: RuleManifest,
    newManifest: RuleManifest,
    oldCases: [FixtureCase],
    newCases: [FixtureCase],
    oldRepoViolationsCount: Int? = nil,
    newRepoViolationsCount: Int? = nil
  ) -> WeakeningReport {
    var items: [WeakeningItem] = []

    // 1. Codes
    for oldCode in oldManifest.codes.keys where newManifest.codes[oldCode] == nil {
      items.append(
        WeakeningItem(
          severity: .red,
          category: "Code",
          message: "Violation code '\(oldCode)' was removed"
        ))
    }

    // 2. Targets
    for oldTarget in oldManifest.targets where !newManifest.targets.contains(oldTarget) {
      items.append(
        WeakeningItem(
          severity: .red,
          category: "Target",
          message: "Target language '\(oldTarget.rawValue)' was removed"
        ))
    }

    // 3. Scopes
    for (target, oldScope) in oldManifest.scope {
      guard let newScope = newManifest.scope[target] else { continue }

      // Narrowed includes
      let oldIncludes = Set(oldScope.include)
      let newIncludes = Set(newScope.include)
      for removed in oldIncludes.subtracting(newIncludes) {
        items.append(
          WeakeningItem(
            severity: .red,
            category: "Scope",
            message: "[\(target.rawValue)] include pattern removed: '\(removed)'"
          ))
      }

      // Broadened excludes
      let oldExcludes = Set(oldScope.exclude ?? [])
      let newExcludes = Set(newScope.exclude ?? [])
      for added in newExcludes.subtracting(oldExcludes) {
        items.append(
          WeakeningItem(
            severity: .red,
            category: "Scope",
            message: "[\(target.rawValue)] exclude pattern added: '\(added)'"
          ))
      }
    }

    // 4. Fixtures - should_fail
    let oldFailCases = oldCases.filter { !$0.isShouldPass }
    let newFailCases = newCases.filter { !$0.isShouldPass }
    let newFailMap = Dictionary(uniqueKeysWithValues: newFailCases.map { ($0.id, $0) })

    for oldCase in oldFailCases {
      guard let newCase = newFailMap[oldCase.id] else {
        items.append(
          WeakeningItem(
            severity: .red,
            category: "Fixture",
            message: "should_fail case '\(oldCase.id)' was removed"
          ))
        continue
      }

      // Compare annotations
      let oldExpSet = Set(oldCase.expectedViolations)
      let newExpSet = Set(newCase.expectedViolations)
      let removedAnnotations = oldExpSet.subtracting(newExpSet)

      for rem in removedAnnotations {
        items.append(
          WeakeningItem(
            severity: .red,
            category: "Fixture",
            message: "Expect annotation for '\(rem.code)' removed in '\(oldCase.id)' at \(rem.relativePath):\(rem.line)"
          ))
      }
    }

    // 5. Green flags - added should_pass and should_fail
    let oldPassMap = Dictionary(uniqueKeysWithValues: oldCases.filter { $0.isShouldPass }.map { ($0.id, $0) })
    for newPass in newCases.filter({ $0.isShouldPass }) where oldPassMap[newPass.id] == nil {
      items.append(
        WeakeningItem(
          severity: .green,
          category: "Fixture",
          message: "should_pass case added: '\(newPass.id)'"
        ))
    }

    let oldFailIdSet = Set(oldFailCases.map { $0.id })
    for newFail in newFailCases where !oldFailIdSet.contains(newFail.id) {
      items.append(
        WeakeningItem(
          severity: .green,
          category: "Fixture",
          message: "should_fail case added: '\(newFail.id)'"
        ))
    }

    // 6. Repo violation count drop
    if let oldViolations = oldRepoViolationsCount, let newViolations = newRepoViolationsCount {
      if newViolations < oldViolations {
        items.append(
          WeakeningItem(
            severity: .red,
            category: "Enforcement",
            message: "Repo violation count dropped from \(oldViolations) to \(newViolations)"
          ))
      }
    }

    return WeakeningReport(ruleId: ruleId, items: items)
  }
}
