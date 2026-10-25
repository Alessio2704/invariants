import Foundation
import Testing

@testable import Core

@Suite("SystemPaths Centralized Paths", .tags(.unit))
struct SystemPathsTests {
  @Test("SystemPaths constants match canonical defaults")
  func systemPathsConstants() {
    #expect(SystemPaths.defaultPrefixPath == "/usr/local/invariants")
    #expect(SystemPaths.defaultPrefixURL.path == "/usr/local/invariants")
    #expect(SystemPaths.defaultBinaryPath == "/usr/local/bin/invariants")
    #expect(SystemPaths.defaultBinaryURL.path == "/usr/local/bin/invariants")
    #expect(SystemPaths.prefixEnvVariable == "INVARIANTS_PREFIX")
    #expect(SystemPaths.binaryRelativeSubpath == "bin/invariants")
    #expect(SystemPaths.versionsDirectoryName == "versions")
    #expect(SystemPaths.currentLinkName == "current")
    #expect(SystemPaths.defaultKeySubpath == ".ssh/invariants_p256")
    #expect(SystemPaths.keyBackupPrefix == "invariants_p256.bak-")
    #expect(SystemPaths.devWorkspaceSubpath == "invariants/.dev")
    #expect(SystemPaths.kitsDirectorySubpath == "kits")
    #expect(SystemPaths.universalIgnoredPaths == [".git", "invariants/.dev", "kits"])
  }

  @Test("SystemEnvironment.standard initializes with SystemPaths defaults")
  func systemEnvironmentStandardDefaults() {
    let env = SystemEnvironment()
    #expect(env.rootURL == SystemPaths.defaultPrefixURL)
    #expect(env.binURL == SystemPaths.defaultBinaryURL)
    #expect(env.versionsDirectoryURL == SystemPaths.defaultPrefixURL.appendingPathComponent("versions"))
    #expect(env.currentVersionURL == SystemPaths.defaultPrefixURL.appendingPathComponent("current"))
    #expect(
      SystemEnvironment.defaultSigningKeyURL
        == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/invariants_p256"))
  }
}
