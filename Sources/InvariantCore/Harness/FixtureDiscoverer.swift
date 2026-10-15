public import Foundation

/// Discovers fixture cases in a rule folder and parses expectations.
public struct FixtureDiscoverer: Sendable {
  private let annotationParser: AnnotationParser

  public init(annotationParser: AnnotationParser = AnnotationParser()) {
    self.annotationParser = annotationParser
  }

  /// Discovers all fixture cases for a target and validates annotations.
  public func discover(
    ruleDirectory: URL,
    target: TargetLanguage,
    manifestCodes: [String: String]
  ) throws(HarnessError) -> [FixtureCase] {
    let fm = FileManager.default
    var cases: [FixtureCase] = []

    // 1. Discover should_pass
    let passDir = ruleDirectory.appendingPathComponent("should_pass/\(target.rawValue)")
    if fm.fileExists(atPath: passDir.path) {
      let passCases = try discoverInDirectory(dirURL: passDir, isShouldPass: true, target: target)
      cases.append(contentsOf: passCases)
    }

    // 2. Discover should_fail
    let failDir = ruleDirectory.appendingPathComponent("should_fail/\(target.rawValue)")
    if fm.fileExists(atPath: failDir.path) {
      let failCases = try discoverInDirectory(dirURL: failDir, isShouldPass: false, target: target)
      cases.append(contentsOf: failCases)
    }

    // 3. Verify code coverage across should_fail cases
    var coveredCodes: Set<String> = []
    for c in cases where !c.isShouldPass {
      for exp in c.expectedViolations {
        coveredCodes.insert(exp.code)
      }
    }

    let missing = manifestCodes.keys.filter { !coveredCodes.contains($0) }.sorted()
    if !missing.isEmpty {
      throw HarnessError.missingCodeCoverage(codes: missing)
    }

    return cases
  }

  private func discoverInDirectory(
    dirURL: URL,
    isShouldPass: Bool,
    target: TargetLanguage
  ) throws(HarnessError) -> [FixtureCase] {
    let fm = FileManager.default
    let contents: [String]
    do {
      contents = try fm.contentsOfDirectory(atPath: dirURL.path)
    } catch {
      throw HarnessError.ioError("Failed to list \(dirURL.path): \(error.localizedDescription)")
    }

    var cases: [FixtureCase] = []
    for entry in contents.sorted() {
      if entry.hasPrefix(".") || entry.hasSuffix(".expect") { continue }
      let entryURL = dirURL.appendingPathComponent(entry)
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: entryURL.path, isDirectory: &isDir) else { continue }

      if isDir.boolValue {
        // Folder case
        let folderCase = try parseFolderCase(folderURL: entryURL, isShouldPass: isShouldPass, target: target)
        cases.append(folderCase)
      } else {
        // File case
        let fileCase = try parseFileCase(fileURL: entryURL, isShouldPass: isShouldPass, target: target)
        cases.append(fileCase)
      }
    }
    return cases
  }

  private func parseFileCase(
    fileURL: URL,
    isShouldPass: Bool,
    target: TargetLanguage
  ) throws(HarnessError) -> FixtureCase {
    let fileName = fileURL.lastPathComponent
    var expected: [ExpectedViolation] = []

    // Inline annotations
    let inline = try annotationParser.parseInlineAnnotations(fileURL: fileURL, relativePath: fileName)
    expected.append(contentsOf: inline)

    // Sidecar .expect
    let sidecarURL = fileURL.deletingLastPathComponent().appendingPathComponent("\(fileName).expect")
    let sidecar = try annotationParser.parseSidecarExpectFile(sidecarURL: sidecarURL, targetRelativePath: fileName)
    expected.append(contentsOf: sidecar)

    if isShouldPass && !expected.isEmpty {
      let first = expected[0]
      throw HarnessError.annotationsForbiddenInShouldPass(caseId: fileName, file: first.relativePath, line: first.line)
    }

    return FixtureCase(
      id: fileName,
      rootURL: fileURL.deletingLastPathComponent(),
      files: [fileURL],
      expectedViolations: expected,
      isShouldPass: isShouldPass,
      target: target
    )
  }

  private func parseFolderCase(
    folderURL: URL,
    isShouldPass: Bool,
    target: TargetLanguage
  ) throws(HarnessError) -> FixtureCase {
    let fm = FileManager.default
    let caseId = folderURL.lastPathComponent
    var expected: [ExpectedViolation] = []

    // Check root expect file
    let rootExpectURL = folderURL.appendingPathComponent("expect")
    if fm.fileExists(atPath: rootExpectURL.path) {
      let folderExpect = try annotationParser.parseFolderExpectFile(expectFileURL: rootExpectURL)
      expected.append(contentsOf: folderExpect)
    }

    var files: [URL] = []
    let enumerator = fm.enumerator(
      at: folderURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])

    let folderPath = folderURL.standardizedFileURL.path
    while let fileURL = enumerator?.nextObject() as? URL {
      let path = fileURL.standardizedFileURL.path
      if fileURL.lastPathComponent == "expect" || fileURL.pathExtension == "expect" { continue }

      var rel = String(path.dropFirst(folderPath.count))
      if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }

      files.append(fileURL)

      // Inline annotations
      let inline = try annotationParser.parseInlineAnnotations(fileURL: fileURL, relativePath: rel)
      expected.append(contentsOf: inline)

      // Sidecar
      let sidecar = fileURL.appendingPathExtension("expect")
      let sidecarExp = try annotationParser.parseSidecarExpectFile(sidecarURL: sidecar, targetRelativePath: rel)
      expected.append(contentsOf: sidecarExp)
    }

    if isShouldPass && !expected.isEmpty {
      let first = expected[0]
      throw HarnessError.annotationsForbiddenInShouldPass(caseId: caseId, file: first.relativePath, line: first.line)
    }

    return FixtureCase(
      id: caseId,
      rootURL: folderURL,
      files: files.sorted { $0.path < $1.path },
      expectedViolations: expected,
      isShouldPass: isShouldPass,
      target: target
    )
  }
}
