public import Foundation

/// Parses inline annotations, sidecar `.expect` files, and folder `expect` files.
public struct AnnotationParser: Sendable {
  public init() {}

  /// Extracts expected violations from inline comments in a file.
  public func parseInlineAnnotations(fileURL: URL, relativePath: String) throws(HarnessError) -> [ExpectedViolation] {
    let content: String
    do {
      content = try String(contentsOf: fileURL, encoding: .utf8)
    } catch {
      throw HarnessError.ioError("Failed to read file \(fileURL.path): \(error.localizedDescription)")
    }

    var results: [ExpectedViolation] = []
    let lines = content.components(separatedBy: .newlines)

    for (zeroIdx, line) in lines.enumerated() {
      let lineNum = zeroIdx + 1
      // Match "// expect:" or "/* expect:" or "# expect:"
      if let range = line.range(of: "expect:", options: .caseInsensitive) {
        let rest = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let clean = rest.replacingOccurrences(of: "*/", with: "").trimmingCharacters(in: .whitespaces)
        let codes = clean.split(separator: ",").map {
          $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        for code in codes {
          results.append(
            ExpectedViolation(
              relativePath: relativePath,
              line: lineNum,
              code: code
            ))
        }
      }
    }
    return results
  }

  public func parseSidecarExpectFile(
    sidecarURL: URL,
    targetRelativePath: String
  ) throws(HarnessError) -> [ExpectedViolation] {
    guard FileManager.default.fileExists(atPath: sidecarURL.path) else { return [] }
    let content: String
    do {
      content = try String(contentsOf: sidecarURL, encoding: .utf8)
    } catch {
      throw HarnessError.ioError("Failed to read sidecar file \(sidecarURL.path): \(error.localizedDescription)")
    }

    var results: [ExpectedViolation] = []
    let lines = content.components(separatedBy: .newlines)

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("//") { continue }

      let parts = trimmed.split(separator: "@").map { $0.trimmingCharacters(in: .whitespaces) }
      guard parts.count == 2, let lineNum = Int(parts[1]) else { continue }
      let code = parts[0]
      results.append(ExpectedViolation(relativePath: targetRelativePath, line: lineNum, code: code))
    }
    return results
  }

  /// Parses folder root `expect` file: `path:line CODE`.
  public func parseFolderExpectFile(expectFileURL: URL) throws(HarnessError) -> [ExpectedViolation] {
    guard FileManager.default.fileExists(atPath: expectFileURL.path) else { return [] }
    let content: String
    do {
      content = try String(contentsOf: expectFileURL, encoding: .utf8)
    } catch {
      throw HarnessError.ioError(
        "Failed to read folder expect file \(expectFileURL.path): \(error.localizedDescription)")
    }

    var results: [ExpectedViolation] = []
    let lines = content.components(separatedBy: .newlines)

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("//") { continue }

      let parts = trimmed.split(separator: " ", maxSplits: 1).map { String($0) }
      guard parts.count == 2 else { continue }
      let pathAndLine = parts[0]
      let code = parts[1].trimmingCharacters(in: .whitespaces)

      let locParts = pathAndLine.split(separator: ":").map { String($0) }
      guard locParts.count == 2, let lineNum = Int(locParts[1]) else { continue }
      let relPath = locParts[0]

      results.append(ExpectedViolation(relativePath: relPath, line: lineNum, code: code))
    }
    return results
  }
}
