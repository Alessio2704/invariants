import Foundation

/// Destination stream for terminal writes.
package enum TerminalStream: Sendable {
  case stdout
  case stderr
}

/// Abstract destination sink for terminal output, allowing in-memory buffering in tests.
package protocol TerminalSink: Sendable {
  func write(_ string: String, to stream: TerminalStream)
  func supportsColor(for stream: TerminalStream) -> Bool
}

/// Standard native terminal output sink writing directly via POSIX / FileHandle.
package struct StandardTerminalSink: TerminalSink {
  package init() {}

  package func write(_ string: String, to stream: TerminalStream) {
    let output = supportsColor(for: stream) ? string : Terminal.stripANSI(string)
    let handle = (stream == .stdout) ? FileHandle.standardOutput : FileHandle.standardError
    if let data = output.data(using: .utf8) {
      handle.write(data)
    }
  }

  package func supportsColor(for stream: TerminalStream) -> Bool {
    Terminal.environmentSupportsColor(for: stream)
  }
}

/// Thread-safe in-memory sink for capturing terminal output in automated test suites.
package final class TerminalTestSink: TerminalSink, @unchecked Sendable {
  private let lock = NSLock()
  private var _stdout: String = ""
  private var _stderr: String = ""
  package var allowsColor: Bool

  package init(allowsColor: Bool = false) {
    self.allowsColor = allowsColor
  }

  package func supportsColor(for stream: TerminalStream) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return allowsColor
  }

  package func write(_ string: String, to stream: TerminalStream) {
    lock.lock()
    defer { lock.unlock() }
    let output = allowsColor ? string : Terminal.stripANSI(string)
    switch stream {
    case .stdout: _stdout += output
    case .stderr: _stderr += output
    }
  }

  package var stdout: String {
    lock.lock()
    defer { lock.unlock() }
    return _stdout
  }

  package var stderr: String {
    lock.lock()
    defer { lock.unlock() }
    return _stderr
  }

  package func clear() {
    lock.lock()
    defer { lock.unlock() }
    _stdout = ""
    _stderr = ""
  }
}
