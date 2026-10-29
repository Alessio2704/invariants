import Foundation
import SwiftSyntax
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

  @Test("Fluent call query matches member expression function calls like apiClient.request")
  func memberCallQuery() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fm = FileManager.default
    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    let swiftCode = """
      func run() async {
          let d1 = await apiClient.request("/api/v1/users")
          let d2 = await client.network.fetch("/api/v1/data")
          let d3 = request("/api/v1/direct")
          let d4 = otherCall("ignore")
      }
      """
    let fileURL = tmpDir.appendingPathComponent("MemberCallSample.swift")
    try swiftCode.data(using: .utf8)?.write(to: fileURL)

    let ctx = RuleContext(
      repoRoot: tmpDir,
      ruleDir: tmpDir,
      files: [fileURL]
    )

    // Test 1: Querying by base member name matches both member accesses and free functions
    let matchesByName = ctx.swift.files
      .calls(named: "request", "fetch")
      .violations(
        code: "TEST-CALL",
        message: { "\($0.callee)" }
      )

    #expect(matchesByName.count == 3)
    #expect(matchesByName[0].line == 2)
    #expect(matchesByName[0].message == "apiClient.request")
    #expect(matchesByName[1].line == 3)
    #expect(matchesByName[1].message == "client.network.fetch")
    #expect(matchesByName[2].line == 4)
    #expect(matchesByName[2].message == "request")

    // Test 2: Querying by full callee expression still works as an exact query
    let matchesByFullCallee = ctx.swift.files
      .calls(named: "apiClient.request")
      .violations(
        code: "TEST-EXACT",
        message: { "\($0.callee)" }
      )

    #expect(matchesByFullCallee.count == 1)
    #expect(matchesByFullCallee[0].line == 2)
  }

  @Test("Multi-unit RuleContext isolates files, AST and syntax per unit while aggregating at top level")
  func multiUnitContextIsolation() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fm = FileManager.default
    let iosDir = tmpDir.appendingPathComponent("ios")
    let vaporDir = tmpDir.appendingPathComponent("vapor")
    try fm.createDirectory(at: iosDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: vaporDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    let iosFile = iosDir.appendingPathComponent("View.swift")
    let vaporFile = vaporDir.appendingPathComponent("Controller.swift")
    try Data("struct MyView { let t = Text(\"Hello\") }".utf8).write(to: iosFile)
    try Data("struct MyController { let t = Text(\"World\") }".utf8).write(to: vaporFile)

    let iosUnit = SwiftASTUnit(
      name: "ios",
      repoRoot: tmpDir,
      files: [iosFile],
      indexStorePath: "ios/store",
      mode: .repo
    )
    let vaporUnit = SwiftASTUnit(
      name: "vapor",
      repoRoot: tmpDir,
      files: [vaporFile],
      indexStorePath: "vapor/store",
      mode: .repo
    )

    let ctx = RuleContext(
      repoRoot: tmpDir,
      ruleDir: tmpDir,
      files: [iosFile, vaporFile],
      ast: ["ios": iosUnit, "vapor": vaporUnit],
      mode: .repo
    )

    // Unit isolation
    let iosAst = try #require(ctx.ast["ios"])
    let vaporAst = try #require(ctx.ast["vapor"])
    #expect(iosAst.files == [iosFile])
    #expect(vaporAst.files == [vaporFile])
    #expect(ctx.files.count == 2)

    // Fluent query pipeline isolated to each unit
    let iosCalls = iosAst.swift.files.calls(named: "Text").violations(
      code: "C", message: { _ in "" }, fix: "")
    #expect(iosCalls.count == 1)
    #expect(iosCalls[0].file.contains("ios/View.swift"))

    let vaporCalls = vaporAst.swift.files.calls(named: "Text").violations(
      code: "C", message: { _ in "" }, fix: "")
    #expect(vaporCalls.count == 1)
    #expect(vaporCalls[0].file.contains("vapor/Controller.swift"))

    // Aggregated top-level query
    let allCalls = ctx.swift.files.calls(named: "Text").violations(code: "C", message: { _ in "" }, fix: "")
    #expect(allCalls.count == 2)

    // Per-unit syntax tree
    let iosSyntax = try iosAst.syntax(iosFile)
    #expect(iosSyntax.statements.count == 1)

    // Per-unit lazy indexStore resolution and INDEX STALE error reporting
    #expect {
      try iosAst.index
    } throws: { error in
      guard let ruleErr = error as? RuleError, case .indexStale(let msg) = ruleErr else { return false }
      return msg.contains("ios") || msg.contains("index store not found")
    }

    #expect {
      try vaporAst.index
    } throws: { error in
      guard let ruleErr = error as? RuleError, case .indexStale(let msg) = ruleErr else { return false }
      return msg.contains("vapor") || msg.contains("index store not found")
    }
  }
}
