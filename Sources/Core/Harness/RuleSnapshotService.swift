public import Foundation

/// Centralized service to manage ephemeral Git snapshots of signed rules for evaluation.
public enum RuleSnapshotService {
  /// Extracts the Git tree of a rule into a sandboxed temporary directory, loads its manifest,
  /// runs the given async operation, and reliably purges the temporary files upon completion.
  public static func withSnapshot<T: Sendable>(
    treeHash: String,
    expectedId: String? = nil,
    operation: (URL, RuleManifest) async throws -> T
  ) async throws -> T {
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory.appendingPathComponent("rule_snap_\(UUID().uuidString)")
    try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer {
      try? fm.removeItem(at: tempDir)
    }

    try await GitClient.archiveExtract(treeHash: treeHash, destinationURL: tempDir)
    let manifestURL = tempDir.appendingPathComponent("manifest.json")
    let manifest = try ManifestParser.load(from: manifestURL, expectedId: expectedId)
    return try await operation(tempDir, manifest)
  }
}
