public import Foundation
public import IndexStoreDB
import SwiftParser
public import SwiftSyntax

/// Execution mode for rule evaluation.
public enum RuleMode: String, Sendable, Codable {
  /// Running against product code in repository.
  case repo
  /// Running against test fixtures during self-test.
  case fixture
}

/// Helper for accessing rule-local assets in `data/` or rule root.
public struct RuleDataAccessor: Sendable {
  /// The directory containing rule files and assets.
  public let ruleDir: URL

  /// Initializes a data accessor for a rule directory.
  public init(ruleDir: URL) {
    self.ruleDir = ruleDir
  }

  /// Loads a set of strings from a JSON array or newline-delimited text file.
  /// - Parameter filename: Filename within `data/` or rule directory.
  public func allowlist(_ filename: String) throws(RuleError) -> Set<String> {
    let linesArray = try lines(filename)
    return Set(linesArray.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
  }

  /// Loads and decodes a JSON asset.
  /// - Parameters:
  ///   - filename: Asset filename.
  ///   - type: Decodable target type.
  public func json<T: Decodable>(_ filename: String, as type: T.Type = T.self) throws(RuleError) -> T {
    let fileURL = resolveAssetURL(filename)
    do {
      let data = try Data(contentsOf: fileURL)
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw RuleError.ioError("Failed to decode JSON asset \(filename): \(error.localizedDescription)")
    }
  }

  /// Loads lines from a text file, stripping empty lines and comment lines starting with `#`.
  /// - Parameter filename: Text filename.
  public func lines(_ filename: String) throws(RuleError) -> [String] {
    let fileURL = resolveAssetURL(filename)
    do {
      let content = try String(contentsOf: fileURL, encoding: .utf8)
      let jsonStrings = try? JSONDecoder().decode([String].self, from: Data(content.utf8))
      if let strings = jsonStrings {
        return strings
      }
      return content.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    } catch {
      throw RuleError.ioError("Failed to read asset \(filename): \(error.localizedDescription)")
    }
  }

  private func resolveAssetURL(_ filename: String) -> URL {
    let dataSubdir = ruleDir.appendingPathComponent("data/\(filename)")
    if FileManager.default.fileExists(atPath: dataSubdir.path) {
      return dataSubdir
    }
    return ruleDir.appendingPathComponent(filename)
  }
}

/// Swift AST context providing query pipelines.
public struct SwiftContext: Sendable {
  /// In-scope Swift source files.
  public let files: SourceFileCollection

  /// Initializes a Swift AST context.
  public init(files: SourceFileCollection) {
    self.files = files
  }
}

/// A compilation/AST unit for Swift analysis.
public final class SwiftASTUnit: @unchecked Sendable {
  public let name: String
  public let repoRoot: URL
  public let files: [URL]
  public let indexStorePath: String?
  public let mode: RuleMode

  public lazy var swift: SwiftContext = {
    SwiftContext(files: SourceFileCollection(files: files, repoRoot: repoRoot))
  }()

  private var cachedIndex: IndexStoreDB?
  private let indexLock = NSLock()
  private var tempDirsToClean: [URL] = []

  deinit {
    for dir in tempDirsToClean {
      try? FileManager.default.removeItem(at: dir)
    }
  }

  public init(
    name: String,
    repoRoot: URL,
    files: [URL],
    indexStorePath: String? = nil,
    mode: RuleMode = .repo
  ) {
    self.name = name
    self.repoRoot = repoRoot
    self.files = files
    self.indexStorePath = indexStorePath
    self.mode = mode
  }

  /// Parses a Swift source file into a SwiftSyntax tree.
  public func syntax(_ file: URL) throws(RuleError) -> SourceFileSyntax {
    do {
      let content = try String(contentsOf: file, encoding: .utf8)
      return Parser.parse(source: content)
    } catch {
      throw RuleError.ioError("Failed to parse SwiftSyntax for \(file.path): \(error.localizedDescription)")
    }
  }

  /// Returns the parsed `SourceFile` for a given file URL if present in this unit.
  public func sourceFile(_ file: URL) -> SourceFile? {
    swift.files.files.first { $0.url == file }
  }

  /// Returns the parsed `SourceFile` for a given path if present in this unit.
  public func sourceFile(_ path: String) -> SourceFile? {
    swift.files.files.first { $0.url.path == path || $0.relativePath == path }
  }

  /// Accesses the unit's IndexStoreDB database, opened lazily and verified for freshness.
  public var index: IndexStoreDB {
    get throws(RuleError) {
      indexLock.lock()
      defer { indexLock.unlock() }

      if let cached = cachedIndex {
        return cached
      }

      let db = try openAndVerifyIndex()
      self.cachedIndex = db
      return db
    }
  }

  private func openAndVerifyIndex() throws(RuleError) -> IndexStoreDB {
    let storePath: String
    let tempDbDir: URL

    if mode == .fixture {
      // Build index on demand for fixture files
      let tmpStore = FileManager.default.temporaryDirectory.appendingPathComponent("fixture_index_\(UUID().uuidString)")
      try? FileManager.default.createDirectory(at: tmpStore, withIntermediateDirectories: true)
      storePath = tmpStore.path
      tempDbDir = FileManager.default.temporaryDirectory.appendingPathComponent("fixture_db_\(UUID().uuidString)")
      tempDirsToClean.append(tmpStore)
      tempDirsToClean.append(tempDbDir)

      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
      var args = ["swiftc", "-typecheck", "-index-store-path", storePath]
      args.append(contentsOf: files.map { $0.path })
      process.arguments = args
      try? process.run()
      process.waitUntilExit()
    } else {
      guard let relIndex = indexStorePath, !relIndex.isEmpty else {
        throw RuleError.indexStale("INDEX STALE — no indexStore configured in registry.ast.swift.\(name)")
      }
      let fullPath = repoRoot.appendingPathComponent(relIndex).standardizedFileURL.path
      guard FileManager.default.fileExists(atPath: fullPath) else {
        throw RuleError.indexStale("INDEX STALE — index store not found at \(fullPath). Build first.")
      }
      storePath = fullPath
      tempDbDir = FileManager.default.temporaryDirectory.appendingPathComponent("invariants_db_\(UUID().uuidString)")
      tempDirsToClean.append(tempDbDir)
    }

    guard let libPath = RuleContext.locateLibIndexStore() else {
      throw RuleError.evaluationError(
        "libIndexStore.dylib not found in active developer toolchain. Run xcode-select or install Command Line Tools."
      )
    }

    let db: IndexStoreDB
    do {
      let lib = try IndexStoreLibrary(dylibPath: libPath)
      db = try IndexStoreDB(storePath: storePath, databasePath: tempDbDir.path, library: lib)
      db.pollForUnitChangesAndWait(isInitialScan: true)
    } catch {
      throw RuleError.evaluationError("Failed to open IndexStoreDB: \(error.localizedDescription)")
    }

    // Freshness check in repo mode
    if mode == .repo {
      for fileURL in files where fileURL.pathExtension == "swift" {
        let fileValues = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
        if let modDate = fileValues?.contentModificationDate {
          guard let unitDate = db.dateOfLatestUnitFor(filePath: fileURL.path) else {
            throw RuleError.indexStale("INDEX STALE — \(fileURL.lastPathComponent) has no index unit. Build first.")
          }
          if modDate > unitDate {
            throw RuleError.indexStale(
              "INDEX STALE — \(fileURL.lastPathComponent) was modified after index was built. Build first.")
          }
        }
      }
    }

    return db
  }
}

/// Execution context provided to each rule invocation.
public final class RuleContext: @unchecked Sendable {
  /// The project repository root URL.
  public let repoRoot: URL

  /// The rule directory URL.
  public let ruleDir: URL

  /// In-scope source files to analyze.
  public let files: [URL]

  /// Named AST units.
  public let ast: [String: SwiftASTUnit]

  /// Evaluation mode: `.repo` or `.fixture`.
  public let mode: RuleMode

  /// Rule data accessor.
  public let data: RuleDataAccessor

  /// Swift AST pipeline across all in-scope files.
  public lazy var swift: SwiftContext = {
    SwiftContext(files: SourceFileCollection(files: files, repoRoot: repoRoot))
  }()

  /// Initializes a RuleContext with named AST units.
  public init(
    repoRoot: URL,
    ruleDir: URL,
    files: [URL],
    ast: [String: SwiftASTUnit] = [:],
    mode: RuleMode = .repo
  ) {
    self.repoRoot = repoRoot
    self.ruleDir = ruleDir
    self.files = files
    self.ast = ast
    self.mode = mode
    self.data = RuleDataAccessor(ruleDir: ruleDir)
  }

  /// Convenience initializer for single-unit or legacy calls.
  public convenience init(
    repoRoot: URL,
    ruleDir: URL,
    files: [URL],
    projectIndexStorePath: String?,
    mode: RuleMode = .repo
  ) {
    let unit = SwiftASTUnit(
      name: "main",
      repoRoot: repoRoot,
      files: files,
      indexStorePath: projectIndexStorePath,
      mode: mode
    )
    self.init(
      repoRoot: repoRoot,
      ruleDir: ruleDir,
      files: files,
      ast: ["main": unit],
      mode: mode
    )
  }

  /// Backward-compatible accessor for primary unit's index store path.
  public var projectIndexStorePath: String? {
    ast.values.min(by: { $0.name < $1.name })?.indexStorePath
  }

  /// Parses a Swift source file into a SwiftSyntax tree.
  public func syntax(_ file: URL) throws(RuleError) -> SourceFileSyntax {
    for unit in ast.values where unit.files.contains(file) {
      return try unit.syntax(file)
    }
    do {
      let content = try String(contentsOf: file, encoding: .utf8)
      return Parser.parse(source: content)
    } catch {
      throw RuleError.ioError("Failed to parse SwiftSyntax for \(file.path): \(error.localizedDescription)")
    }
  }

  /// Accesses the IndexStoreDB database from the primary configured AST unit.
  public var index: IndexStoreDB {
    get throws(RuleError) {
      if let primary = ast.values.min(by: { $0.name < $1.name }) {
        return try primary.index
      }
      throw RuleError.indexStale("INDEX STALE — no Swift AST units available")
    }
  }

  package static func locateLibIndexStore() -> String? {
    let fm = FileManager.default

    // 1. Try querying xcode-select -p
    let pipe = Pipe()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    proc.arguments = ["-p"]
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    if (try? proc.run()) != nil {
      proc.waitUntilExit()
      if proc.terminationStatus == 0 {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let rawDev = String(bytes: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let devPath = rawDev, !devPath.isEmpty {
          let candidate = URL(fileURLWithPath: devPath)
            .appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib").path
          if fm.fileExists(atPath: candidate) {
            return candidate
          }
        }
      }
    }

    // 2. Try querying xcrun --find swift
    let xcrunPipe = Pipe()
    let xcrunProc = Process()
    xcrunProc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    xcrunProc.arguments = ["--find", "swift"]
    xcrunProc.standardOutput = xcrunPipe
    xcrunProc.standardError = Pipe()
    if (try? xcrunProc.run()) != nil {
      xcrunProc.waitUntilExit()
      if xcrunProc.terminationStatus == 0 {
        let data = xcrunPipe.fileHandleForReading.readDataToEndOfFile()
        let rawSwift = String(bytes: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let swiftPath = rawSwift, !swiftPath.isEmpty {
          let candidate = URL(fileURLWithPath: swiftPath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("lib/libIndexStore.dylib").path
          if fm.fileExists(atPath: candidate) {
            return candidate
          }
        }
      }
    }

    // 3. Fallback standard toolchain locations
    let standardCandidates = [
      "/Library/Developer/CommandLineTools/usr/lib/libIndexStore.dylib",
      "/usr/lib/libIndexStore.dylib",
    ]
    for cand in standardCandidates where fm.fileExists(atPath: cand) {
      return cand
    }

    return nil
  }
}
