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

private struct InternalSwiftProj: Decodable {
  let indexStore: String?
}

private struct InternalProject: Decodable {
  let swift: InternalSwiftProj?
}

private struct InternalRuleRequest: Decodable {
  let mode: String
  let repoRoot: String
  let ruleDir: String
  let files: [String]
  let project: InternalProject?
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
    let repoRoot = URL(fileURLWithPath: request.repoRoot)
    let ruleDir = URL(fileURLWithPath: request.ruleDir)
    let fileURLs = request.files.map { URL(fileURLWithPath: $0) }
    let indexStorePath = request.project?.swift?.indexStore

    let ctx = RuleContext(
      repoRoot: repoRoot,
      ruleDir: ruleDir,
      files: fileURLs,
      projectIndexStorePath: indexStorePath,
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
