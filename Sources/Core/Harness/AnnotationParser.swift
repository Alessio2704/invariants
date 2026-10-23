public import Foundation

/// Parses inline annotations, sidecar `.expect` files, and folder `expect` files.
public enum AnnotationParser: Sendable {
  /// Extracts expected violations from inline comments in a file.
  public static func parseInlineAnnotations(
    fileURL: URL,
    relativePath: String
  ) throws(HarnessError) -> [ExpectedViolation] {
    let content: String
    do {
      content = try fileURL.readUTF8()
    } catch {
      throw HarnessError.ioError("Failed to read file \(fileURL.path): \(error.localizedDescription)")
    }

    var results: [ExpectedViolation] = []
    let lines = content.components(separatedBy: .newlines)

    for (zeroIdx, line) in lines.enumerated() {
      let lineNum = zeroIdx + 1
      // Match "// expect:" or "/* expect:" or "# expect:"
      if let range = line.range(of: "expect:", options: .caseInsensitive) {
        let rest = line[range.upperBound...].trimmed
        let clean = rest.replacingOccurrences(of: "*/", with: "").trimmed
        let delimiters = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ","))
        let codes = clean.components(separatedBy: delimiters).map(\.trimmed).filter { !$0.isEmpty }

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

  public static func parseSidecarExpectFile(
    sidecarURL: URL,
    targetRelativePath: String
  ) throws(HarnessError) -> [ExpectedViolation] {
    guard FileManager.default.fileExists(atPath: sidecarURL.path) else { return [] }
    let content: String
    do {
      content = try sidecarURL.readUTF8()
    } catch {
      throw HarnessError.ioError("Failed to read sidecar file \(sidecarURL.path): \(error.localizedDescription)")
    }

    var results: [ExpectedViolation] = []
    let lines = content.components(separatedBy: .newlines)

    for line in lines {
      let trimmed = line.trimmed
      if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("//") { continue }

      let parts = trimmed.split(separator: "@").map(\.trimmed)
      guard parts.count == 2, let lineNum = Int(parts[1]) else { continue }
      let code = parts[0]
      results.append(ExpectedViolation(relativePath: targetRelativePath, line: lineNum, code: code))
    }
    return results
  }

  /// Parses folder root `expect` file: `path:line CODE`.
  public static func parseFolderExpectFile(expectFileURL: URL) throws(HarnessError) -> [ExpectedViolation] {
    guard FileManager.default.fileExists(atPath: expectFileURL.path) else { return [] }
    let content: String
    do {
      content = try expectFileURL.readUTF8()
    } catch {
      throw HarnessError.ioError(
        "Failed to read folder expect file \(expectFileURL.path): \(error.localizedDescription)")
    }

    var results: [ExpectedViolation] = []
    let lines = content.components(separatedBy: .newlines)

    for line in lines {
      let trimmed = line.trimmed
      if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("//") { continue }

      let parts = trimmed.split(separator: " ", maxSplits: 1).map { String($0) }
      guard parts.count == 2 else { continue }
      let pathAndLine = parts[0]
      let code = parts[1].trimmed

      let locParts = pathAndLine.split(separator: ":").map { String($0) }
      guard locParts.count == 2, let lineNum = Int(locParts[1]) else { continue }
      let relPath = locParts[0]

      results.append(ExpectedViolation(relativePath: relPath, line: lineNum, code: code))
    }
    return results
  }
}
