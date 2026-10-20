import Foundation

/// Destination stream for terminal writes.
package enum TerminalStream: Sendable {
  case stdout
  case stderr
}

/// Abstract destination sink for terminal output, allowing in-memory buffering in tests.
package protocol TerminalSink: Sendable {
  func write(_ string: String, to stream: TerminalStream)
}

/// Standard native terminal output sink writing directly via POSIX / FileHandle.
package struct StandardTerminalSink: TerminalSink {
  package init() {}

  package func write(_ string: String, to stream: TerminalStream) {
    let handle = (stream == .stdout) ? FileHandle.standardOutput : FileHandle.standardError
    if let data = string.data(using: .utf8) {
      handle.write(data)
    }
  }
}

/// Thread-safe in-memory sink for capturing terminal output in automated test suites.
package final class TerminalTestSink: TerminalSink, @unchecked Sendable {
  private let lock = NSLock()
  private var _stdout: String = ""
  private var _stderr: String = ""

  package init() {}

  package func write(_ string: String, to stream: TerminalStream) {
    lock.lock()
    defer { lock.unlock() }
    switch stream {
    case .stdout: _stdout += string
    case .stderr: _stderr += string
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
