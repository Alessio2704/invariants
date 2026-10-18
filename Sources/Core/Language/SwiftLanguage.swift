public import Foundation

/// Swift language specification requiring an Apple / Clang index store.
public enum SwiftLanguage: LanguageSpec {
  public static let language = SupportedLanguage.swift
  public static let displayName = "Swift"
  public static let sourceExtensions = ["swift"]
  public static let ruleFileName = "rule.swift"
  public static let defaultIgnoredPaths = [".build", "build"]
  public static let defaultIgnoredExtensions: [String] = []
  public static let executionSpec = RuleExecutionSpec(
    model: .compiled(
      CompiledSpec(
        buildToolchain: .xcrun,
        buildArguments: ["swift", "build"],
        kitPackageName: "kit-swift",
        artifactRelativePath: ".build/release/RuleExecutable",
        debugArtifactRelativePath: ".build/debug/RuleExecutable",
        sourceExtensions: ["swift"],
        manifestKind: .swiftPackage(
          toolsVersion: "6.0",
          targetName: "RuleExecutable",
          productName: "InvariantKit"
        )
      )
    ),
    reporting: RuleReportingProtocol(
      channel: .stdoutJSON,
      successExitCode: 0,
      staleIndexExitCode: 2,
      staleIndexStderrMarker: "INDEX STALE"
    )
  )

  /// Swift requires a single index store path for IndexStoreDB / symbol graph analysis.
  public struct Config: LanguageConfiguration, Equatable {
    public var indexStore: String

    public init(indexStore: String) {
      self.indexStore = indexStore
    }

    public func toCanonicalJSON() -> String? {
      "{ \"indexStore\": \"\(CanonicalJSON.escape(indexStore))\" }"
    }
  }

  public static func describeConfig(in languages: LanguagesConfig) -> String {
    languages[Self.self]?.indexStore ?? "none"
  }

  public static func discoverCandidates(repoRootURL: URL) -> [String] {
    let fm = FileManager.default
    var candidates: [String] = []
    let rootURL = repoRootURL.resolvingSymlinksInPath()
    let rootPath = rootURL.path

    if let enumerator = fm.enumerator(
      at: rootURL,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) {
      while let fileURL = enumerator.nextObject() as? URL {
        let path = fileURL.resolvingSymlinksInPath().path
        if SupportedLanguage.shouldSkipAny(url: fileURL, repoRoot: rootURL) {
          if fileURL.lastPathComponent == "build" {
            // Allow searching within build directory for Index.noindex/DataStore
          } else {
            enumerator.skipDescendants()
            continue
          }
        }
        if path.hasSuffix("Index.noindex/DataStore") {
          guard path.hasPrefix(rootPath) else { continue }
          var rel = String(path.dropFirst(rootPath.count))
          if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
          candidates.append(rel)
        }
      }
    }
    let spmStore = rootURL.appendingPathComponent(".build/debug/index/store")
    if fm.fileExists(atPath: spmStore.path) {
      candidates.append(".build/debug/index/store")
    }
    let spmOut = rootURL.appendingPathComponent(".build/out")
    if fm.fileExists(atPath: spmOut.path) {
      candidates.append(".build/out")
    }
    let xcodeStore = rootURL.appendingPathComponent("build/Index.noindex/DataStore")
    if fm.fileExists(atPath: xcodeStore.path) {
      candidates.append("build/Index.noindex/DataStore")
    }
    return Array(Set(candidates)).sorted()
  }

  public static let configPromptDescriptor = LanguageConfigPromptDescriptor(
    noCandidatesMessage: "Swift sources detected, but no index store candidate was found "
      + "(e.g. build/Index.noindex/DataStore, .build/out, or .build/debug/index/store).",
    manualPromptQuestion: "Enter index store path (press Enter to skip / configure later)",
    selectionStyle: .single(selectionTitle: "Discovered Swift Index candidates:")
  )

  public static func makeConfig(from paths: [String]) -> (any LanguageConfiguration)? {
    guard let first = paths.first, !first.isEmpty else { return nil }
    return Config(indexStore: first)
  }

  public static func devWorkspaceFiles(repoRootURL: URL, environment: SystemEnvironment) -> [DevWorkspaceFile] {
    let fm = FileManager.default
    let kitSwiftURL = environment.kitURL(named: "kit-swift")
    let repoKitURL = repoRootURL.appendingPathComponent("kits/kit-swift")
    let kitSwiftPath =
      fm.fileExists(atPath: kitSwiftURL.path)
      ? kitSwiftURL.path
      : (fm.fileExists(atPath: repoKitURL.path) ? repoKitURL.path : repoRootURL.path)
    let kitPackageName =
      URL(fileURLWithPath: kitSwiftPath).lastPathComponent == "kit-swift" ? "kit-swift" : "invariants"

    let devPackage = """
      // swift-tools-version: 6.0
      import PackageDescription

      let package = Package(
          name: "InvariantsDev",
          platforms: [.macOS(.v14)],
          dependencies: [
              .package(path: "\(kitSwiftPath)")
          ],
          targets: [
              .target(
                  name: "InvariantsDev",
                  dependencies: [
                      .product(name: "InvariantKit", package: "\(kitPackageName)")
                  ],
                  path: "."
              )
          ]
      )
      """
    return [DevWorkspaceFile(relativePath: "Package.swift", content: devPackage)]
  }
}
