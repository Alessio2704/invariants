import Foundation

/// Destination stream for terminal writes.
package enum TerminalStream: Sendable {
  case stdout
  case stderr
}

/// Abstract destination sink for terminal output.
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
