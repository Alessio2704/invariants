import Extensions
import Foundation

/// Centralized, type-safe terminal presentation and output subsystem for invariants CLI.
package enum Terminal {
  @TaskLocal package static var customSink: (any TerminalSink)?

  private static let defaultSink = StandardTerminalSink()

  package static var sink: any TerminalSink {
    customSink ?? defaultSink
  }

  // MARK: - Scoped Execution for Testing

  @discardableResult
  package static func withSink<T>(_ sink: any TerminalSink, operation: () throws -> T) rethrows -> T {
    try $customSink.withValue(sink) {
      try operation()
    }
  }

  // MARK: - TTY & Interactive Inspection

  package static var isInteractive: Bool {
    isatty(FileHandle.standardInput.fileDescriptor) != 0
  }

  // MARK: - Low-Level Writing

  package static func write(_ string: String, to stream: TerminalStream = .stdout) {
    sink.write(string, to: stream)
  }

  // MARK: - Semantic Channels

  /// Emits a standardized error message to stderr.
  package static func error(_ message: String) {
    sink.write("Error: \(message)\n", to: .stderr)
  }

  /// Emits a standardized warning message to stderr.
  package static func warning(_ message: String) {
    sink.write("Warning: \(message)\n", to: .stderr)
  }

  /// Emits a success notice to stdout with a checkmark.
  package static func success(_ message: String) {
    sink.write("✓ \(message)\n", to: .stdout)
  }

  /// Emits an informational message to stdout.
  package static func info(_ message: String) {
    sink.write("\(message)\n", to: .stdout)
  }

  /// Emits an empty line or line of text to stdout.
  package static func line(_ message: String = "") {
    sink.write("\(message)\n", to: .stdout)
  }

  // MARK: - Structured Presentation

  /// Emits a titled section header underlined by a horizontal divider line.
  package static func header(
    _ title: String,
    divider: Character = "─",
    to stream: TerminalStream = .stdout
  ) {
    let count = max(title.count, 16)
    let dividerLine = String(repeating: divider, count: count)
    sink.write("\(title)\n\(dividerLine)\n", to: stream)
  }

  /// Emits a formatted key-value field aligned to a specified column width.
  package static func field(
    _ label: String,
    value: String,
    width: Int = 13,
    to stream: TerminalStream = .stdout
  ) {
    let padded = label.padding(toLength: width, withPad: " ", startingAt: 0)
    sink.write("\(padded) \(value)\n", to: stream)
  }

  /// Emits an indented list item with a bullet or custom marker.
  package static func item(
    _ text: String,
    bullet: String = "•",
    indent: Int = 2,
    to stream: TerminalStream = .stdout
  ) {
    let spaces = String(repeating: " ", count: indent)
    sink.write("\(spaces)\(bullet) \(text)\n", to: stream)
  }

  /// Emits a numbered list item.
  package static func numbered(
    _ number: Int,
    text: String,
    to stream: TerminalStream = .stdout
  ) {
    sink.write("  [\(number)] \(text)\n", to: stream)
  }

  /// Emits a status item (e.g. `  ✓ item: detail` or `  ✗ item`).
  package static func statusItem(
    _ symbol: String,
    label: String,
    detail: String? = nil,
    to stream: TerminalStream = .stdout
  ) {
    if let detail {
      sink.write("  \(symbol) \(label): \(detail)\n", to: stream)
    } else {
      sink.write("  \(symbol) \(label)\n", to: stream)
    }
  }

  /// Emits an actionable hint or tip.
  package static func hint(_ text: String, to stream: TerminalStream = .stdout) {
    sink.write("💡 \(text)\n", to: stream)
  }
}
