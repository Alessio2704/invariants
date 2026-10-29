import Foundation
import Testing

@testable import Core

@Suite("Fixture Harness & Parsing", .tags(.unit))
struct HarnessTests {
  @Test("Inline annotation parsing identifies line number and code")
  func inlineAnnotationParsing() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let sampleSwift = """
      import SwiftUI

      struct Foo {
          let label = Text("Bad") // expect: RAW-TEXT
          let other = 123
          let btn = Button("Click") // expect: RAW-TEXT, BUTTON-LABEL
      }
      """
    let fileURL = tmpDir.appendingPathComponent("Sample.swift")
    try sampleSwift.data(using: .utf8)?.write(to: fileURL)

    let expected = try AnnotationParser.parseInlineAnnotations(fileURL: fileURL, relativePath: "Sample.swift")

    #expect(expected.count == 3)
    #expect(expected[0].code == "RAW-TEXT")
    #expect(expected[0].line == 4)
    #expect(expected[1].code == "RAW-TEXT")
    #expect(expected[1].line == 6)
    #expect(expected[2].code == "BUTTON-LABEL")
    #expect(expected[2].line == 6)
  }

  @Test("Sidecar .expect parsing")
  func sidecarParsing() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let sidecarContent = """
      # Sidecar expectation
      RAW-TEXT @ 42
      EMPTY-CATALOG @ 0
      """
    let sidecarURL = tmpDir.appendingPathComponent("sample.json.expect")
    try sidecarContent.data(using: .utf8)?.write(to: sidecarURL)

    let expected = try AnnotationParser.parseSidecarExpectFile(
      sidecarURL: sidecarURL, targetRelativePath: "sample.json")

    #expect(expected.count == 2)
    #expect(expected[0].code == "RAW-TEXT")
    #expect(expected[0].line == 42)
    #expect(expected[1].code == "EMPTY-CATALOG")
    #expect(expected[1].line == 0)
  }

  @Test("Annotations are strictly forbidden in should_pass fixtures")
  func annotationsForbiddenInPass() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fm = FileManager.default
    let passDir = tmpDir.appendingPathComponent("should_pass/swift")
    let failDir = tmpDir.appendingPathComponent("should_fail/swift")
    try fm.createDirectory(at: passDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: failDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    // Put an expect annotation inside should_pass
    let illegalPassFile = passDir.appendingPathComponent("Illegal.swift")
    try Data("// expect: TOY-01\nlet x = 1\n".utf8).write(to: illegalPassFile)

    let legalFailFile = failDir.appendingPathComponent("Bad.swift")
    try Data("// expect: TOY-01\nlet y = 2\n".utf8).write(to: legalFailFile)

    #expect(throws: HarnessError.self) {
      _ = try FixtureDiscoverer.discover(
        ruleDirectory: tmpDir,
        target: .swift,
        manifestCodes: ["TOY-01": "Desc"]
      )
    }
  }

  @Test("Multi-unit fixture mapping for folder cases vs flat cases")
  func multiUnitFixtureMapping() throws {
    let fm = FileManager.default
    let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmpDir) }

    // Multi-unit folder case: should_fail/swift/dto_mismatch/{ios,vapor}
    let failDir = tmpDir.appendingPathComponent("should_fail/swift/dto_mismatch")
    let iosDir = failDir.appendingPathComponent("ios")
    let vaporDir = failDir.appendingPathComponent("vapor")
    try fm.createDirectory(at: iosDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: vaporDir, withIntermediateDirectories: true)

    let clientFile = iosDir.appendingPathComponent("Client.swift")
    let serverFile = vaporDir.appendingPathComponent("Server.swift")
    try Data("// expect: DTO-01\nlet client = 1".utf8).write(to: clientFile)
    try Data("// Server code".utf8).write(to: serverFile)

    // Flat should_pass case: should_pass/swift/case1.swift
    let passDir = tmpDir.appendingPathComponent("should_pass/swift")
    try fm.createDirectory(at: passDir, withIntermediateDirectories: true)
    let flatPass = passDir.appendingPathComponent("case1.swift")
    try Data("// Legitimate".utf8).write(to: flatPass)

    let cases = try FixtureDiscoverer.discover(
      ruleDirectory: tmpDir,
      target: .swift,
      manifestCodes: ["DTO-01": "Desc"]
    )
    #expect(cases.count == 2)

    let folderCase = try #require(cases.first { !$0.isShouldPass })
    #expect(folderCase.id == "dto_mismatch")
    #expect(folderCase.files.count == 2)
  }
}
