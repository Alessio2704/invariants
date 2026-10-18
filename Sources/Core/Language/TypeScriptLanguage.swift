public import Foundation

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
        kitRunnerRelativePath: "dist/runner.js",
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

  /// TypeScript requires an array of relative tsconfig.json paths for compiler API / ts-morph.
  public struct Config: LanguageConfiguration, Equatable {
    public var tsconfig: [String]

    public init(tsconfig: [String]) {
      self.tsconfig = tsconfig
    }

    public func toCanonicalJSON() -> String? {
      let formatted = tsconfig.map { "\"\(CanonicalJSON.escape($0))\"" }.joined(separator: ", ")
      return "{ \"tsconfig\": [\(formatted)] }"
    }
  }

  public static func describeConfig(in languages: LanguagesConfig) -> String {
    let list = languages[Self.self]?.tsconfig ?? []
    return list.isEmpty ? "none" : list.joined(separator: ", ")
  }

  public static func discoverCandidates(repoRootURL: URL) -> [String] {
    let fm = FileManager.default
    var candidates: [String] = []
    let rootURL = repoRootURL.resolvingSymlinksInPath()
    let rootPath = rootURL.path

    if let enumerator = fm.enumerator(
      at: rootURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) {
      while let fileURL = enumerator.nextObject() as? URL {
        if SupportedLanguage.shouldSkipAny(url: fileURL, repoRoot: rootURL) {
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
    noCandidatesMessage: "TypeScript sources detected, but no tsconfig.json candidate was found.",
    manualPromptQuestion: "Enter tsconfig relative path (press Enter to skip / configure later)",
    manualFallbackQuestion: "Enter tsconfig relative path (press Enter to skip)",
    selectionStyle: .multiple(confirmationQuestion: "Use discovered tsconfig paths")
  )

  public static func makeConfig(from paths: [String]) -> (any LanguageConfiguration)? {
    let filtered = paths.filter { !$0.isEmpty }
    guard !filtered.isEmpty else { return nil }
    return Config(tsconfig: filtered)
  }

  public static func devWorkspaceFiles(repoRootURL: URL, environment: SystemEnvironment) -> [DevWorkspaceFile] {
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
