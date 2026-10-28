import Foundation
import Testing

@testable import Core
@testable import Workflows

@Suite("Security Attacks: Shell Injection & Privilege Escalation", .serialized, .tags(.securityAttack))
struct ShellAndPrivilegeAttackTests {

  @Test("SEC-01: SelfUpdateWorkflow command injection via unescaped git tag in shell pipeline")
  func sec01_selfUpdateCommandInjectionViaTag() async throws {
    let fixture = try await AuditProjectFixture()
    try await fixture.verifyBaseline()

    let markerURL = fixture.baseDir.appendingPathComponent("pwned_sec01")
    #expect(!FileManager.default.fileExists(atPath: markerURL.path))

    // Craft a tag that breaks out of single quotes in:
    // git archive '<tag>' | tar -x -C '<workDir>'
    let injectedTag = "v1.0.0'; touch '\(markerURL.path)' #"

    let repoRoot = (try? RepoLocator.discover()) ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let binaryURL = repoRoot.appendingPathComponent(".build/out/Products/Debug/invariants")

    if FileManager.default.fileExists(atPath: binaryURL.path) {
      _ = try? await SubprocessRunner.run(
        executableURL: binaryURL,
        arguments: ["self-update", injectedTag],
        workingDirectory: fixture.repoURL,
        environment: [
          "INVARIANTS_PREFIX": fixture.sandboxPrefixURL.path,
          "INVARIANTS_REPO": fixture.baseDir.appendingPathComponent("nonexistent_repo").path,
          "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
      )
    }

    // Secure invariant: An unescaped tag must NEVER execute arbitrary shell commands
    #expect(
      !FileManager.default.fileExists(atPath: markerURL.path),
      "Vulnerability SEC-01 confirmed: arbitrary shell command was executed via tag interpolation!"
    )
  }

  @Test("SEC-02a: install.sh command injection via unescaped TAG argument in root subshell")
  func sec02a_installScriptCommandInjectionViaTag() async throws {
    let repoRoot = (try? RepoLocator.discover()) ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let installShURL = repoRoot.appendingPathComponent("install.sh")
    guard FileManager.default.fileExists(atPath: installShURL.path) else {
      #expect(Bool(false), "install.sh not found at \(installShURL.path)")
      return
    }

    let installScript = try installShURL.readUTF8()

    // Lines 47-67 in install.sh invoke:
    // $SUDO /bin/sh -c "set -e
    //   mkdir -p '$PREFIX/versions/$V'
    //   ...
    // In secure shell scripting, variables interpolated into a subshell must either be passed
    // as positional parameters (e.g. /bin/sh -c '... "$1" ...' _ "$V") or TAG must be strictly validated.
    let interpolatesVWithoutEscaping = installScript.contains("mkdir -p '$PREFIX/versions/$V'")
    let passesPositionalParams =
      installScript.contains("/bin/sh -c '") && installScript.contains(" \"$PREFIX\" \"$V\"")
    let validatesTagRegex = installScript.contains("^[0-9]") || installScript.contains("expr \"$TAG\" :")

    #expect(
      !interpolatesVWithoutEscaping || passesPositionalParams || validatesTagRegex,
      "Vulnerability SEC-02a confirmed: install.sh interpolates unescaped $V into root /bin/sh -c subshell string!"
    )
  }

  @Test("SEC-02b: install.sh hardcodes /usr/local/bin symlink even when custom prefix is configured")
  func sec02b_installScriptCustomPrefixEncapsulation() async throws {
    let repoRoot = (try? RepoLocator.discover()) ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let installShURL = repoRoot.appendingPathComponent("install.sh")
    let installScript = try installShURL.readUTF8()

    // Line 64 of install.sh unconditionally creates symlink at /usr/local/bin/invariants
    // without respecting INVARIANTS_PREFIX or checking if PREFIX contains its own bin directory
    let hasHardcodedUsrLocalBin = installScript.contains(
      "ln -sfn '$PREFIX/current/invariants' /usr/local/bin/invariants")
    let usesPrefixBin =
      installScript.contains("ln -sfn '$PREFIX/current/invariants' \"$PREFIX/bin/invariants\"")
      || installScript.contains("${BIN_DIR:-/usr/local/bin}")

    #expect(
      !hasHardcodedUsrLocalBin && usesPrefixBin,
      "Vulnerability SEC-02b confirmed: install.sh hardcodes unconditional write to /usr/local/bin!"
    )
  }

  @Test("SEC-03: Authorizer.authorizeElevation public validator allows forging ElevationToken")
  func sec03_publicElevationValidatorBypass() async throws {
    guard !Authorizer.isRunningAsRoot else { return }

    // Authorizer.authorizeElevation declares elevationValidator as a public parameter with default nil:
    // public static func authorizeElevation(reason: String, elevationValidator: (...) async throws -> Void)
    // An attacker or rogue script can pass a no-op closure: elevationValidator: {}
    // and receive a valid, unforgeable ElevationToken without ever prewarming sudo or authenticating!

    // The secure behavior is that authorizeElevation MUST NOT allow external/unauthorized callers
    // to bypass sudo verification with a custom closure when not executing as root.
    let token = try await Authorizer.authorizeElevation(
      reason: "Attacker forging capability token",
      elevationValidator: {
        // No-op closure bypassing sudo -v
      }
    )

    // Secure invariant: An unauthenticated caller must NOT receive a valid ElevationToken!
    #expect(
      !token.isValid,
      "Vulnerability SEC-03 confirmed: Authorizer issued valid ElevationToken with no-op elevationValidator!"
    )
  }
}
