public import Foundation

/// Request payload passed to rule subprocesses.
public struct RuleRequest: Sendable, Codable {
  public let mode: String  // "repo" or "fixture"
  public let repoRoot: String
  public let ruleDir: String
  public let files: [String]
  public let languages: LanguagesConfig

  public init(
    mode: String,
    repoRoot: String,
    ruleDir: String,
    files: [String],
    languages: LanguagesConfig
  ) {
    self.mode = mode
    self.repoRoot = repoRoot
    self.ruleDir = ruleDir
    self.files = files
    self.languages = languages
  }
}

/// A violation emitted by a rule.
public struct ReportedViolation: Sendable, Codable, Equatable, Hashable {
  public let code: String
  public let file: String
  public let line: Int
  public let column: Int
  public let message: String
  public let fix: String
}

/// Declarative manifest specification for building compiled rule packages.
public enum CompiledManifestKind: Sendable, Equatable {
  /// Swift Package Manager (Package.swift)
  case swiftPackage(toolsVersion: String, targetName: String, productName: String)
}

/// Declarative specification for an ahead-of-time compiled rule (e.g. Swift, Rust).
public struct CompiledSpec: Sendable, Equatable {
  /// Build toolchain binary (e.g. SystemBinary.xcrun with "swift", or custom binary).
  public var buildToolchain: SystemBinary
  /// Arguments to invoke the build toolchain.
  public var buildArguments: [String]
  /// Subdirectory or package name of the kit dependency.
  public var kitPackageName: String
  /// Relative path to the output executable artifact inside cache directory.
  public var artifactRelativePath: String
  /// Alternative debug artifact path if release is not present.
  public var debugArtifactRelativePath: String?
  /// Source file extensions to copy from rule directory to cache sources.
  public var sourceExtensions: [String]
  /// Manifest generation kind.
  public var manifestKind: CompiledManifestKind

  public init(
    buildToolchain: SystemBinary,
    buildArguments: [String],
    kitPackageName: String,
    artifactRelativePath: String,
    debugArtifactRelativePath: String?,
    sourceExtensions: [String],
    manifestKind: CompiledManifestKind
  ) {
    self.buildToolchain = buildToolchain
    self.buildArguments = buildArguments
    self.kitPackageName = kitPackageName
    self.artifactRelativePath = artifactRelativePath
    self.debugArtifactRelativePath = debugArtifactRelativePath
    self.sourceExtensions = sourceExtensions
    self.manifestKind = manifestKind
  }
}

/// Declarative specification for an interpreted / JIT-executed rule (e.g. TypeScript, Python).
public struct InterpretedSpec: Sendable, Equatable {
  /// The runtime command to locate (e.g. "node", "python3").
  public var runtimeCommand: String
  /// Subdirectory name of the kit (e.g. "kit-ts").
  public var kitDirectoryName: String
  /// Relative path to the kit harness script within the kit directory (e.g. "dist/runner.js").
  public var kitRunnerRelativePath: String
  /// Fallback runner path inside kit during local development (e.g. "src/runner.ts").
  public var devRunnerRelativePath: String

  public init(
    runtimeCommand: String,
    kitDirectoryName: String,
    kitRunnerRelativePath: String,
    devRunnerRelativePath: String
  ) {
    self.runtimeCommand = runtimeCommand
    self.kitDirectoryName = kitDirectoryName
    self.kitRunnerRelativePath = kitRunnerRelativePath
    self.devRunnerRelativePath = devRunnerRelativePath
  }
}

/// Execution model archetype.
public enum RuleExecutionModel: Sendable, Equatable {
  case compiled(CompiledSpec)
  case interpreted(InterpretedSpec)
}

/// Reporting protocol and exit code conventions used by the rule process.
public struct RuleReportingProtocol: Sendable, Equatable {
  public enum Channel: Sendable, Equatable {
    case stdoutJSON
  }

  public var channel: Channel
  public var successExitCode: Int32
  public var staleIndexExitCode: Int32
  public var staleIndexStderrMarker: String?

  public init(
    channel: Channel,
    successExitCode: Int32,
    staleIndexExitCode: Int32,
    staleIndexStderrMarker: String?
  ) {
    self.channel = channel
    self.successExitCode = successExitCode
    self.staleIndexExitCode = staleIndexExitCode
    self.staleIndexStderrMarker = staleIndexStderrMarker
  }
}

/// Complete declarative specification of how a language builds, runs, and communicates with rules.
public struct RuleExecutionSpec: Sendable, Equatable {
  public var model: RuleExecutionModel
  public var reporting: RuleReportingProtocol

  public init(
    model: RuleExecutionModel,
    reporting: RuleReportingProtocol
  ) {
    self.model = model
    self.reporting = reporting
  }
}

public enum RuleRunnerError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
  case ruleCrashed(exitCode: Int32, stderr: String)
  case ruleHung(timeoutSeconds: Double)
  case indexStale(String)
  case invalidOutput(String)
  case executableBuildFailed(String)
  case nodeNotFound
  case runtimeNotFound(String)
  case kitNotFound(String)
  case systemError(String)

  public var errorDescription: String? {
    switch self {
    case .ruleCrashed(let exitCode, let stderr):
      return "RULE CRASHED (exit code \(exitCode)): \(stderr)"
    case .ruleHung(let timeout):
      return "RULE HUNG (timed out after \(Int(timeout))s)"
    case .indexStale(let msg):
      return "INDEX STALE — \(msg)"
    case .invalidOutput(let msg):
      return "Invalid rule output: \(msg)"
    case .executableBuildFailed(let msg):
      return "Failed to build rule executable: \(msg)"
    case .nodeNotFound:
      return "Node.js executable not found"
    case .runtimeNotFound(let cmd):
      return "Runtime executable '\(cmd)' not found"
    case .kitNotFound(let msg):
      return "Rule kit not found: \(msg)"
    case .systemError(let msg):
      return "System error: \(msg)"
    }
  }

  public var description: String {
    errorDescription ?? "RuleRunnerError"
  }
}
