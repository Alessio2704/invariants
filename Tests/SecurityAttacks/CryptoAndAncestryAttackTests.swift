import Foundation
import Testing

@testable import Core
@testable import Managers
@testable import Workflows

@Suite("Security Attacks: Cryptography, Ancestry & Floor Protection", .serialized, .tags(.securityAttack))
struct CryptoAndAncestryAttackTests {

  @Test("SEC-04a: Spoofed GIT_COMMITTER_DATE bypasses key expiration in checkSignerAncestry")
  func sec04a_spoofedGitCommitterDateBypassesKeyExpiration() async throws {
    let fixture = try await AuditProjectFixture()
    try await fixture.verifyBaseline()

    // 1. Enroll contractor key with valid-before in the past (e.g. 2025-01-01)
    let signersURL = fixture.repoURL.appendingPathComponent("invariants/allowed_signers")
    var signersContent = try signersURL.readUTF8()
    let expiredContractorEntry =
      "* namespaces=\"invariants\",valid-before=\"20250101000000Z\" \(fixture.contractorPub)\n"
    signersContent.append(expiredContractorEntry)
    try signersContent.write(to: signersURL, atomically: true, encoding: .utf8)

    // Commit v2 with ownerKey authorizing the sunset key
    let reg2 = Registry(
      version: 2,
      engine: EngineVersion.defaultRange,
      defaultBranch: "main",
      languages: AuditProjectFixture.defaultLanguages,
      ast: AuditProjectFixture.defaultAST,
      rules: [:]
    )
    try await fixture.run {
      try await RegistryManager.saveAndSign(registry: reg2, keyURL: fixture.ownerKey)
      try await GitClient.commit(paths: ["invariants"], message: "Enroll contractor with expiration")
    }

    // 2. Attacker uses contractorKey (which expired in 2025) to forge v3 in 2026,
    // but spoofs GIT_COMMITTER_DATE to 2024-06-01 (before expiration).
    let reg3 = Registry(
      version: 3,
      engine: EngineVersion.defaultRange,
      defaultBranch: "main",
      languages: AuditProjectFixture.defaultLanguages,
      ast: AuditProjectFixture.defaultAST,
      rules: [:]
    )

    try await fixture.run {
      try await RegistryManager.saveAndSign(registry: reg3, keyURL: fixture.contractorKey)

      // Commit with spoofed committer date
      _ = try await SubprocessRunner.run(
        binary: .git,
        arguments: [
          "-C", fixture.repoURL.path,
          "commit",
          "-a",
          "-m", "Rogue commit using expired key with spoofed timestamp",
          "--date", "2024-06-01T12:00:00Z",
        ],
        environment: [
          "GIT_COMMITTER_DATE": "2024-06-01T12:00:00Z",
          "GIT_AUTHOR_DATE": "2024-06-01T12:00:00Z",
        ]
      )

      // Secure Invariant: FloorGuard must NOT accept an expired key just because the committer date was backdated!
      await #expect(
        throws: FloorError.self,
        "Vulnerability SEC-04a confirmed: spoofed commit date allowed expired key to pass checkSignerAncestry!"
      ) {
        try await FloorGuard.checkSignerAncestry(currentRegistry: reg3)
      }
    }
  }

  @Test("SEC-04b: GitClient.commitDate formats local timestamp without UTC timezone conversion")
  func sec04b_commitDateUsesLocalTimezoneWithoutUTCSuffix() async throws {
    let fixture = try await AuditProjectFixture()

    // Create a commit with an explicit non-UTC timezone offset (+0900)
    let testFileURL = fixture.repoURL.appendingPathComponent("tz_test.txt")
    try "tz".write(to: testFileURL, atomically: true, encoding: .utf8)

    _ = try await SubprocessRunner.run(
      binary: .git,
      arguments: ["-C", fixture.repoURL.path, "add", "tz_test.txt"]
    )
    _ = try await SubprocessRunner.run(
      binary: .git,
      arguments: ["-C", fixture.repoURL.path, "commit", "-m", "TZ test commit"],
      environment: [
        "GIT_COMMITTER_DATE": "2026-06-15T12:00:00+0900",
        "GIT_AUTHOR_DATE": "2026-06-15T12:00:00+0900",
      ]
    )

    let headCommit = try await SubprocessRunner.run(
      binary: .git,
      arguments: ["-C", fixture.repoURL.path, "rev-parse", "HEAD"]
    ).trimmedStdout

    let formattedDate =
      await fixture.run {
        await GitClient.commitDate(commit: headCommit)
      } ?? ""

    // The docstring states: "Returns the commit's author date in UTC formatted as 'yyyyMMddHHmmss'".
    // 12:00:00 +0900 in UTC is 03:00:00 UTC (20260615030000 or 20260615030000Z).
    // Today, git log --format=%cd --date=format:%Y%m%d%H%M%S emits local 20260615120000 without Z.
    let isUTC = formattedDate == "20260615030000" || formattedDate == "20260615030000Z"

    #expect(
      isUTC,
      "Vulnerability SEC-04b confirmed: commitDate returned '\(formattedDate)' instead of UTC (20260615030000)!"
    )
  }

  @Test("SEC-05a: Shallow clone (--depth 1) completely bypasses checkSignerAncestry")
  func sec05a_shallowCloneBypassesSignerAncestry() async throws {
    let fixture = try await AuditProjectFixture()
    try await fixture.verifyBaseline()

    // Rogue agent generates rogue key, replaces allowed_signers, and signs v2
    let signersURL = fixture.repoURL.appendingPathComponent("invariants/allowed_signers")
    let rogueSigners = "* namespaces=\"invariants\" \(fixture.rogueAgentPub)\n"
    try rogueSigners.write(to: signersURL, atomically: true, encoding: .utf8)

    let reg2 = Registry(
      version: 2,
      engine: EngineVersion.defaultRange,
      defaultBranch: "main",
      languages: AuditProjectFixture.defaultLanguages,
      ast: AuditProjectFixture.defaultAST,
      rules: [:]
    )

    try await fixture.run {
      try await RegistryManager.saveAndSign(registry: reg2, keyURL: fixture.rogueAgentKey)
      try await GitClient.commit(paths: ["invariants"], message: "Rogue agent commit v2")
    }

    // Now clone the repository with shallow depth 1 (the standard CI checkout mode)
    let shallowDir = fixture.baseDir.appendingPathComponent("shallow_clone")
    _ = try await SubprocessRunner.run(
      binary: .git,
      arguments: ["clone", "--depth", "1", "file://\(fixture.repoURL.path)", shallowDir.path]
    )

    // Inside the shallow clone, HEAD^ does not exist.
    // In FloorGuard.swift:150-161, when showFile(commit: "HEAD^", ...) fails,
    // it falls back to: signersToVerifyAgainst = commitSigners
    // verifying HEAD against its OWN rogue allowed_signers and returning success!
    await #expect(
      throws: FloorError.self,
      "Vulnerability SEC-05a confirmed: shallow clone accepted forged registry signed by unauthorized key!"
    ) {
      try await RepoLocator.withRepoRoot(shallowDir) {
        let currentReg = try await RegistryManager.loadAndVerify(identity: "*")
        try await FloorGuard.checkSignerAncestry(currentRegistry: currentReg)
      }
    }
  }

  @Test("SEC-05b: Git history simplification without --full-history prunes branched registry modifications")
  func sec05b_mergeHistorySimplificationBypassesSignerAncestry() async throws {
    let fixture = try await AuditProjectFixture()

    // Create a side branch that modifies registry.lock
    _ = try await SubprocessRunner.run(
      binary: .git, arguments: ["-C", fixture.repoURL.path, "checkout", "-b", "side-branch"])

    let regSide = Registry(
      version: 2,
      engine: EngineVersion.defaultRange,
      defaultBranch: "main",
      languages: AuditProjectFixture.defaultLanguages,
      ast: AuditProjectFixture.defaultAST,
      rules: [:]
    )
    try await fixture.run {
      try await RegistryManager.saveAndSign(registry: regSide, keyURL: fixture.ownerKey)
      try await GitClient.commit(paths: ["invariants"], message: "Side branch registry change")
    }
    let sideCommit = try await SubprocessRunner.run(
      binary: .git,
      arguments: ["-C", fixture.repoURL.path, "rev-parse", "HEAD"]
    ).trimmedStdout

    // Switch back to main and create a concurrent commit
    _ = try await SubprocessRunner.run(
      binary: .git, arguments: ["-C", fixture.repoURL.path, "checkout", "main"])
    try "concurrent change\n".write(
      to: fixture.repoURL.appendingPathComponent("concurrent.txt"), atomically: true, encoding: .utf8)
    _ = try await SubprocessRunner.run(
      binary: .git, arguments: ["-C", fixture.repoURL.path, "add", "concurrent.txt"])
    _ = try await SubprocessRunner.run(
      binary: .git, arguments: ["-C", fixture.repoURL.path, "commit", "-m", "Concurrent change on main"])

    // Merge side branch into main with -s ours strategy.
    // In Git, path-filtered git log without --full-history prunes side branches whose changes
    // match parent 1, completely hiding the rogue side branch commit from ancestry inspection!
    _ = try await SubprocessRunner.run(
      binary: .git,
      arguments: [
        "-C", fixture.repoURL.path, "merge", "-s", "ours", "side-branch",
        "-m", "Merge side branch with ours strategy",
      ]
    )

    // GitClient.commitHistoryTouching runs:
    // git log --format=%H -- invariants/registry.lock (WITHOUT --full-history)
    let history = try await fixture.run {
      try await GitClient.commitHistoryTouching(relativePath: "invariants/registry.lock")
    }

    #expect(
      history.contains(sideCommit),
      "Vulnerability SEC-05b confirmed: git log history simplification pruned side branch commit touching registry.lock!"
    )
  }

  @Test("SEC-09: Registry with nil/empty signers_hash bypasses allowed_signers integrity verification")
  func sec09_omittedSignersHashBypassesAllowedSignersIntegrity() async throws {
    let fixture = try await AuditProjectFixture()
    try await fixture.verifyBaseline()

    // Tamper with allowed_signers directly by appending rogue key
    let signersURL = fixture.repoURL.appendingPathComponent("invariants/allowed_signers")
    var signersContent = try signersURL.readUTF8()
    signersContent.append("* namespaces=\"invariants\" \(fixture.rogueAgentPub)\n")
    try signersContent.write(to: signersURL, atomically: true, encoding: .utf8)

    // In RegistryManager.swift:47:
    // if let expectedSignersHash = registry.signersHash, !expectedSignersHash.isEmpty
    // If signers_hash is omitted from registry.lock, loadAndVerify skips checking signers_hash!
    let lockURL = fixture.repoURL.appendingPathComponent("invariants/registry.lock")
    let lockData = try Data(contentsOf: lockURL)
    var reg = try CanonicalJSON.parse(data: lockData)
    reg.signersHash = nil

    try await fixture.run {
      let canonicalContent = CanonicalJSON.serialize(reg)
      guard let data = canonicalContent.data(using: .utf8) else {
        throw RegistryError.encodingFailed("Failed to encode canonical JSON as UTF-8")
      }
      try data.write(to: lockURL, options: .atomic)
      try await SigningClient.sign(
        keyURL: fixture.ownerKey,
        namespace: "invariants",
        fileURL: lockURL
      )

      // Secure behavior: RegistryManager MUST verify allowed_signers integrity and reject missing signers_hash
      await #expect(
        throws: RegistryError.self,
        "Vulnerability SEC-09 confirmed: loadAndVerify succeeded despite tampered allowed_signers when signers_hash was omitted!"
      ) {
        _ = try await RegistryManager.loadAndVerify()
      }
    }
  }

  @Test("SEC-10a: FloorGuard.checkNoRewrite empty stdin and refspec bypass")
  func sec10a_prePushEmptyStdinAndRefspecBypass() async throws {
    // Calling checkNoRewrite with empty stdin returns cleanly without checking anything
    // Even if remote push rewrite occurred
    await #expect(
      throws: FloorError.self,
      "Vulnerability SEC-10a confirmed: checkNoRewrite permitted push when stdin input was empty!"
    ) {
      try await FloorGuard.checkNoRewrite(pushedRefsInput: "", defaultBranch: "main")
    }
  }

  @Test("DRIFT-04: Historical signature verification fails for expired named principals")
  func drift04_expiredNamedPrincipalFailsHistoricalVerification() async throws {
    let fixture = try await AuditProjectFixture()
    try await fixture.verifyBaseline()

    // Backdate Commit 1 so that historical commits have monotonic dates
    _ = try await SubprocessRunner.run(
      binary: .git,
      arguments: ["-C", fixture.repoURL.path, "commit", "--amend", "--no-edit", "--date", "2024-01-01T00:00:00Z"],
      environment: [
        "GIT_COMMITTER_DATE": "2024-01-01T00:00:00Z",
        "GIT_AUTHOR_DATE": "2024-01-01T00:00:00Z",
      ]
    )

    // Commit 2: Enroll alice@acme.com with valid-before in the future relative to Commit 2
    // but in the past relative to current wall clock (e.g. 2025-01-01)
    let signersURL = fixture.repoURL.appendingPathComponent("invariants/allowed_signers")
    let updatedSigners = """
      * namespaces="invariants" \(fixture.ownerPub)
      alice@acme.com namespaces="invariants",valid-before="20250101000000Z" \(fixture.contractorPub)

      """
    try updatedSigners.write(to: signersURL, atomically: true, encoding: .utf8)

    let reg2 = Registry(
      version: 2,
      engine: EngineVersion.defaultRange,
      defaultBranch: "main",
      languages: AuditProjectFixture.defaultLanguages,
      ast: AuditProjectFixture.defaultAST,
      rules: [:]
    )
    try await fixture.run {
      try await RegistryManager.saveAndSign(registry: reg2, keyURL: fixture.ownerKey)
      _ = try await SubprocessRunner.run(
        binary: .git,
        arguments: [
          "-C", fixture.repoURL.path,
          "commit",
          "-a",
          "-m", "Enroll alice with sunset",
          "--date", "2024-02-01T12:00:00Z",
        ],
        environment: [
          "GIT_COMMITTER_DATE": "2024-02-01T12:00:00Z",
          "GIT_AUTHOR_DATE": "2024-02-01T12:00:00Z",
        ]
      )
    }

    // Commit 3: Legitimate historical commit signed by alice in 2024 (before expiration)
    let reg3 = Registry(
      version: 3,
      engine: EngineVersion.defaultRange,
      defaultBranch: "main",
      languages: AuditProjectFixture.defaultLanguages,
      ast: AuditProjectFixture.defaultAST,
      rules: [:]
    )
    try await fixture.run {
      try await RegistryManager.saveAndSign(registry: reg3, keyURL: fixture.contractorKey)
      _ = try await SubprocessRunner.run(
        binary: .git,
        arguments: [
          "-C", fixture.repoURL.path,
          "commit",
          "-a",
          "-m", "Alice signed v3 before expiration",
          "--date", "2024-06-01T12:00:00Z",
        ],
        environment: [
          "GIT_COMMITTER_DATE": "2024-06-01T12:00:00Z",
          "GIT_AUTHOR_DATE": "2024-06-01T12:00:00Z",
        ]
      )

      // When checkSignerAncestry walks history, it calls SigningClient.findPrincipal.
      // But findPrincipal does not pass -Overify-time! OpenSSH evaluates valid-before against
      // wall-clock time, returns nil, falls back to -I owner, and rejects the valid historical commit!
      await #expect(
        throws: Never.self,
        "Drift DRIFT-04 confirmed: historical commit signed by alice@acme.com failed ancestry check after key expired!"
      ) {
        try await FloorGuard.checkSignerAncestry(currentRegistry: reg3)
      }
    }
  }
}

extension AuditProjectFixture {
  static var defaultLanguages: [SupportedLanguage] {
    [.swift, .ts]
  }

  static var defaultAST: ASTConfig {
    var ast = ASTConfig()
    ast[SwiftLanguage.self] = ["main": SwiftLanguage.Config(indexStore: "build/Index.noindex/DataStore")]
    ast[TypeScriptLanguage.self] = ["web": TypeScriptLanguage.Config(tsconfig: "web/tsconfig.json")]
    return ast
  }
}
