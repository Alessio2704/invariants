import Extensions
import Foundation
import Testing

@Suite("Lightweight Extensions Library Tests")
struct ExtensionsTests {
  @Test("String.trimmed removes whitespace and newlines")
  func stringTrimmed() {
    #expect("  hello world  \n".trimmed == "hello world")
    #expect("\n\t  ".trimmed.isEmpty)
    #expect("no-whitespace".trimmed == "no-whitespace")
  }

  @Test("Substring.trimmed removes whitespace and newlines")
  func substringTrimmed() {
    let original = "  foo  ,  bar  "
    let parts = original.split(separator: ",").map(\.trimmed)
    #expect(parts == ["foo", "bar"])
  }

  @Test("URL.readUTF8 and URL.readTrimmedUTF8 read file contents correctly")
  func urlReadUTF8() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ext_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let fileURL = tmpDir.appendingPathComponent("test.txt")
    try "  sample content \n".write(to: fileURL, atomically: true, encoding: .utf8)

    #expect(try fileURL.readUTF8() == "  sample content \n")
    #expect(try fileURL.readTrimmedUTF8() == "sample content")
  }

  @Test("URL.readUTF8 throws when file does not exist")
  func urlReadUTF8Throws() {
    let missingURL = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")
    #expect(throws: (any Error).self) {
      _ = try missingURL.readUTF8()
    }
    #expect(throws: (any Error).self) {
      _ = try missingURL.readTrimmedUTF8()
    }
  }
}
