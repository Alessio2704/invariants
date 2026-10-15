import Foundation
import Testing

@testable import InvariantKit

@Suite("InvariantKit Fluent AST and Rule API", .tags(.unit))
struct KitTests {
  @Test("Fluent call query captures string literals and excludes allowlisted terms")
  func fluentCallQuery() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fm = FileManager.default
    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    let swiftCode = """
      import SwiftUI

      struct ViewSample {
          let t1 = Text("Save")
          let t2 = Text("AllowedRaw")
          let t3 = Button("OK")
          let t4 = Label(dynamicVar)
      }
      """
    let fileURL = tmpDir.appendingPathComponent("Sample.swift")
    try swiftCode.data(using: .utf8)?.write(to: fileURL)

    let allowlist: Set<String> = ["AllowedRaw"]

    let ctx = RuleContext(
      repoRoot: tmpDir,
      ruleDir: tmpDir,
      files: [fileURL]
    )

    let violations = ctx.swift.files
      .calls(named: "Text", "Button")
      .whereFirstArgument(is: .stringLiteral)
      .excluding(allowlist)
      .violations(
        code: "RAW-TEXT",
        message: { "\($0.callee) uses raw literal: \($0.firstArgumentStringValue ?? "")" },
        fix: "Use catalog"
      )

    #expect(violations.count == 2)
    #expect(violations[0].code == "RAW-TEXT")
    #expect(violations[0].line == 4)
    #expect(violations[0].message.contains("Save"))
    #expect(violations[1].code == "RAW-TEXT")
    #expect(violations[1].line == 6)
    #expect(violations[1].message.contains("OK"))
  }

  @Test("RuleDataAccessor reads allowlists and lines accurately")
  func ruleDataAccessor() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fm = FileManager.default
    let dataDir = tmpDir.appendingPathComponent("data")
    try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    let jsonList = "[\"item1\", \"item2\", \"item3\"]"
    try jsonList.data(using: .utf8)?.write(to: dataDir.appendingPathComponent("allowlist.json"))

    let accessor = RuleDataAccessor(ruleDir: tmpDir)
    let set = try accessor.allowlist("allowlist.json")
    #expect(set == Set(["item1", "item2", "item3"]))
  }
}
