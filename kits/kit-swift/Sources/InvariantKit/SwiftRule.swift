import Foundation

/// Protocol that every Swift invariant rule implements.
public protocol SwiftRule: Sendable {
  /// Initializes an instance of the rule.
  init()

  /// Evaluates the rule against the provided context and returns violations.
  /// - Parameter ctx: The rule execution context.
  /// - Throws: `RuleError` on unrecoverable analysis failure or stale index.
  func check(_ ctx: RuleContext) throws(RuleError) -> [Violation]
}

private struct InternalSwiftConfig: Decodable {
  let indexStore: String?
}

private struct InternalASTConfig: Decodable {
  let swift: [String: InternalSwiftConfig]?
}

private struct InternalLanguages: Decodable {
  let swift: InternalSwiftConfig?
}

private struct InternalRuleRequest: Decodable {
  let mode: String?
  let repoRoot: String?
  let ruleDir: String?
  let files: [String]?
  let unitFiles: [String: [String]]?
  let ast: InternalASTConfig?
  let languages: InternalLanguages?
}

extension SwiftRule {
  /// Process entrypoint when executed as a standalone binary by `RuleRunner`.
  public static func main() async {
    let args = CommandLine.arguments
    var requestPath: String?

    var i = 1
    while i < args.count {
      if args[i] == "--request" && i + 1 < args.count {
        requestPath = args[i + 1]
        i += 2
      } else if !args[i].hasPrefix("-") {
        requestPath = args[i]
        i += 1
      } else {
        i += 1
      }
    }

    guard let path = requestPath else {
      fputs("Usage: rule [--request <path/to/request.json>]\n", stderr)
      exit(1)
    }

    let requestData: Data
    do {
      requestData = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
      fputs("Failed to read request file at \(path): \(error.localizedDescription)\n", stderr)
      exit(1)
    }

    let request: InternalRuleRequest
    do {
      request = try JSONDecoder().decode(InternalRuleRequest.self, from: requestData)
    } catch {
      fputs("Failed to decode request JSON: \(error.localizedDescription)\n", stderr)
      exit(1)
    }

    let mode: RuleMode = (request.mode == "fixture") ? .fixture : .repo
    let repoRoot = URL(fileURLWithPath: request.repoRoot ?? FileManager.default.currentDirectoryPath)
    let ruleDir = URL(fileURLWithPath: request.ruleDir ?? FileManager.default.currentDirectoryPath)
    let fileURLs = (request.files ?? []).map { URL(fileURLWithPath: $0) }

    var astUnits: [String: SwiftASTUnit] = [:]
    if let unitFiles = request.unitFiles, !unitFiles.isEmpty {
      for (unitName, paths) in unitFiles {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let store = request.ast?.swift?[unitName]?.indexStore ?? request.languages?.swift?.indexStore
        astUnits[unitName] = SwiftASTUnit(
          name: unitName,
          repoRoot: repoRoot,
          files: urls,
          indexStorePath: store,
          mode: mode
        )
      }
    } else {
      let store =
        request.ast?.swift?["main"]?.indexStore ?? request.ast?.swift?.values.first?.indexStore
        ?? request.languages?.swift?.indexStore
      astUnits["main"] = SwiftASTUnit(
        name: "main",
        repoRoot: repoRoot,
        files: fileURLs,
        indexStorePath: store,
        mode: mode
      )
    }

    let ctx = RuleContext(
      repoRoot: repoRoot,
      ruleDir: ruleDir,
      files: fileURLs,
      ast: astUnits,
      mode: mode
    )

    let rule = Self()
    do {
      let violations = try rule.check(ctx)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let outputData = try encoder.encode(violations)
      FileHandle.standardOutput.write(outputData)
      exit(0)
    } catch let ruleErr as RuleError {
      switch ruleErr {
      case .indexStale(let msg):
        fputs("INDEX STALE — \(msg)\n", stderr)
        exit(2)
      case .ioError(let msg), .evaluationError(let msg):
        fputs("Rule error: \(msg)\n", stderr)
        exit(1)
      }
    } catch {
      fputs("Unexpected error: \(error.localizedDescription)\n", stderr)
      exit(1)
    }
  }
}
