import Foundation

/// TypeScript language specification requiring one or more tsconfig.json configurations.
public enum TypeScriptLanguage: LanguageSpec {
  public static let language = SupportedLanguage.ts
  public static let displayName = "TypeScript"
  public static let ruleFileName = "rule.ts"
  public static let sourceExtensions = ["ts", "tsx", "js", "jsx"]
  public static let defaultIgnoredPaths = ["node_modules", "dist"]
  public static let defaultIgnoredExtensions = ["d.ts", "map"]
  public static let executionSpec = RuleExecutionSpec(
    model: .interpreted(
      InterpretedSpec(
        runtimeCommand: "node",
        kitDirectoryName: "kit-ts",
        kitRunnerRelativePath: "src/runner.ts",
        devRunnerRelativePath: "src/runner.ts"
      )
    ),
    reporting: RuleReportingProtocol(
      channel: .stdoutJSON,
      successExitCode: 0,
      staleIndexExitCode: 2,
      staleIndexStderrMarker: "INDEX STALE"
    )
  )

  /// TypeScript requires a relative tsconfig.json path per unit for compiler API / ts-morph.
  public struct Config: LanguageConfiguration, Equatable {
    public var tsconfig: String

    public init(tsconfig: String) {
      self.tsconfig = tsconfig
    }

    public func toCanonicalJSON() -> String? {
      "{ \"tsconfig\": \"\(CanonicalJSON.escape(tsconfig))\" }"
    }
  }

  public static func describeConfig(in ast: ASTConfig) -> String {
    let units = ast[Self.self]
    guard !units.isEmpty else { return "none" }
    return units.sorted(by: { $0.key < $1.key }).map { "\($0.key) (\($0.value.tsconfig))" }.joined(separator: ", ")
  }

  public static func discoverAnalysisInputs() -> [String] {
    let fm = FileManager.default
    var candidates: [String] = []
    let rootURL = RepoLocator.current.resolvingSymlinksInPath()
    let rootPath = rootURL.path

    if let enumerator = fm.enumerator(
      at: rootURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) {
      while let fileURL = enumerator.nextObject() as? URL {
        if SupportedLanguage.shouldSkipAny(url: fileURL) {
          enumerator.skipDescendants()
          continue
        }
        let fileName = fileURL.lastPathComponent
        if fileName.hasPrefix("tsconfig") && fileName.hasSuffix(".json") {
          let path = fileURL.resolvingSymlinksInPath().path
          guard path.hasPrefix(rootPath) else { continue }
          var rel = String(path.dropFirst(rootPath.count))
          if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
          candidates.append(rel)
        }
      }
    }
    return candidates.sorted()
  }

  public static let configPromptDescriptor = LanguageConfigPromptDescriptor(
    noInputsFoundMessage: "TypeScript sources detected, but no tsconfig.json was found.",
    manualPromptQuestion: "Enter tsconfig relative path (press Enter to skip / configure later)",
    manualFallbackQuestion: "Enter tsconfig relative path (press Enter to skip)",
    selectionStyle: .multiple(confirmationQuestion: "Use discovered tsconfig paths")
  )

  public static func makeUnitConfig(from path: String) -> (any LanguageConfiguration)? {
    guard !path.isEmpty else { return nil }
    return Config(tsconfig: path)
  }

  // periphery:ignore
  public static func makeConfig(from paths: [String]) -> (any LanguageConfiguration)? {
    guard let first = paths.first, !first.isEmpty else { return nil }
    return makeUnitConfig(from: first)
  }

  public static func devWorkspaceFiles(environment: SystemEnvironment) -> [DevWorkspaceFile] {
    let devTsconfig = """
      {
        "compilerOptions": {
          "target": "ES2022",
          "module": "NodeNext",
          "moduleResolution": "NodeNext",
          "strict": true
        },
        "include": ["../rules/**/*.ts"]
      }
      """
    return [DevWorkspaceFile(relativePath: "tsconfig.json", content: devTsconfig)]
  }
}
