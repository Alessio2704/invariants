import Foundation
import Testing

@testable import InvariantCore

@Suite("SystemBinary Enum", .tags(.unit))
struct SystemBinaryTests {
  @Test("All system binaries map to canonical paths and exist on macOS host")
  func systemBinaryCanonicalPaths() {
    #expect(SystemBinary.allCases.count == 6)

    #expect(SystemBinary.git.path == "/usr/bin/git")
    #expect(SystemBinary.sshKeygen.path == "/usr/bin/ssh-keygen")
    #expect(SystemBinary.xcrun.path == "/usr/bin/xcrun")
    #expect(SystemBinary.sudo.path == "/usr/bin/sudo")
    #expect(SystemBinary.tar.path == "/usr/bin/tar")
    #expect(SystemBinary.sh.path == "/bin/sh")

    let fm = FileManager.default
    for binary in SystemBinary.allCases {
      #expect(binary.url == URL(fileURLWithPath: binary.path))
      #expect(binary.url.path == binary.rawValue)
      #expect(fm.fileExists(atPath: binary.path), "Expected binary to exist at \(binary.path)")
    }
  }

  @Test("ProcessRunning executes command via SystemBinary overload")
  func processRunningWithSystemBinary() async throws {
    let runner = SubprocessRunner()
    let output = try await runner.run(
      binary: .sh,
      arguments: ["-c", "echo 'system_binary_invocation'"]
    )
    #expect(output.exitCode == 0)
    #expect(output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "system_binary_invocation")
  }
}
