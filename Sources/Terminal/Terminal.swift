import Extensions
import Foundation

/// Centralized, type-safe terminal presentation and output subsystem for invariants CLI.
package enum Terminal {
  @TaskLocal package static var customSink: (any TerminalSink)?
  @TaskLocal package static var customSource: (any TerminalSource)?

  private static let defaultSink = StandardTerminalSink()
  private static let defaultSource = StandardTerminalSource()

  private static let ansiRegex = try? NSRegularExpression(
    pattern: "\\u001B\\[[0-9;]*[a-zA-Z]",
    options: []
  )

  package static var sink: any TerminalSink {
    customSink ?? defaultSink
  }

  package static var source: any TerminalSource {
    customSource ?? defaultSource
  }

  // MARK: - Scoped Execution for Testing

  @discardableResult
  package static func withSink<T>(_ sink: any TerminalSink, operation: () throws -> T) rethrows -> T {
    try $customSink.withValue(sink) {
      try operation()
    }
  }

  @discardableResult
  package static func withSource<T>(_ source: any TerminalSource, operation: () throws -> T) rethrows -> T {
    try $customSource.withValue(source) {
      try operation()
    }
  }

  // MARK: - TTY, Color & Interactive Inspection

  package static var isInteractive: Bool {
    source.isInteractive
  }

  package static func readLine() -> String? {
    source.readLine()
  }

  package static func supportsColor(for stream: TerminalStream = .stdout) -> Bool {
    sink.supportsColor(for: stream)
  }

  /// Determines whether color is enabled based on POSIX environment standards (NO_COLOR, CLICOLOR, CLICOLOR_FORCE, TERM).
  package static func environmentSupportsColor(
    for stream: TerminalStream,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    let tty =
      (stream == .stdout)
      ? isatty(FileHandle.standardOutput.fileDescriptor) != 0
      : isatty(FileHandle.standardError.fileDescriptor) != 0
    return environmentSupportsColor(for: stream, environment: environment, isTTY: tty)
  }

  /// Determines whether color is enabled based on POSIX environment standards with explicit TTY capability.
  package static func environmentSupportsColor(
    for _: TerminalStream,
    environment: [String: String],
    isTTY: Bool
  ) -> Bool {
    if let force = environment["CLICOLOR_FORCE"], force != "0" {
      return true
    }
    if let noColor = environment["NO_COLOR"], !noColor.isEmpty {
      return false
    }
    if environment["CLICOLOR"] == "0" {
      return false
    }
    if environment["TERM"] == "dumb" {
      return false
    }
    return isTTY
  }

  /// Strips all ANSI escape sequences from a string.
  package static func stripANSI(_ string: String) -> String {
    guard string.contains("\u{001B}") else { return string }
    guard let regex = ansiRegex else { return string }
    let range = NSRange(location: 0, length: string.utf16.count)
    return regex.stringByReplacingMatches(in: string, options: [], range: range, withTemplate: "")
  }

  // MARK: - ANSI Styling & Formatting

  /// Formats text with ANSI color and style if color output is supported for the target stream.
  package static func styled(
    _ text: String,
    color: TerminalColor? = nil,
    style: TerminalStyle? = nil,
    stream: TerminalStream = .stdout
  ) -> String {
    guard supportsColor(for: stream) else { return text }
    return format(text, color: color, style: style)
  }

  /// Unconditionally wraps text with ANSI escape codes for the specified color and style.
  package static func format(
    _ text: String,
    color: TerminalColor? = nil,
    style: TerminalStyle? = nil
  ) -> String {
    var codes: [Int] = []
    if let style {
      codes.append(style.rawCode)
    }
    if let color {
      codes.append(color.rawCode)
    }
    guard !codes.isEmpty else { return text }
    let prefix = "\u{001B}[" + codes.map(String.init).joined(separator: ";") + "m"
    let suffix = "\u{001B}[0m"
    return "\(prefix)\(text)\(suffix)"
  }

  // MARK: - Low-Level Writing

  package static func write(_ string: String, to stream: TerminalStream = .stdout) {
    sink.write(string, to: stream)
  }

  // MARK: - Semantic Channels

  /// Emits a standardized error message to stderr.
  package static func error(_ message: String) {
    let prefix = styled("Error:", color: .red, style: .bold, stream: .stderr)
    sink.write("\(prefix) \(message)\n", to: .stderr)
  }

  /// Emits a standardized warning message to stderr.
  package static func warning(_ message: String) {
    let prefix = styled("Warning:", color: .yellow, style: .bold, stream: .stderr)
    sink.write("\(prefix) \(message)\n", to: .stderr)
  }

  /// Emits a success notice to stdout with a checkmark.
  package static func success(_ message: String) {
    let symbol = styled("✓", color: .green, style: .bold, stream: .stdout)
    sink.write("\(symbol) \(message)\n", to: .stdout)
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
    let styledTitle = styled(title, style: .bold, stream: stream)
    let styledDivider = styled(dividerLine, color: .gray, stream: stream)
    sink.write("\(styledTitle)\n\(styledDivider)\n", to: stream)
  }

  /// Emits a formatted key-value field aligned to a specified column width.
  package static func field(
    _ label: String,
    value: String,
    width: Int = 13,
    to stream: TerminalStream = .stdout
  ) {
    let padded = label.padding(toLength: width, withPad: " ", startingAt: 0)
    let styledLabel = styled(padded, color: .gray, stream: stream)
    sink.write("\(styledLabel) \(value)\n", to: stream)
  }

  /// Emits an indented list item with a bullet or custom marker.
  package static func item(
    _ text: String,
    bullet: String = "•",
    indent: Int = 2,
    to stream: TerminalStream = .stdout
  ) {
    let spaces = String(repeating: " ", count: indent)
    let styledBullet = styled(bullet, color: .cyan, stream: stream)
    sink.write("\(spaces)\(styledBullet) \(text)\n", to: stream)
  }

  /// Emits a numbered list item.
  package static func numbered(
    _ number: Int,
    text: String,
    to stream: TerminalStream = .stdout
  ) {
    let tag = styled("[\(number)]", color: .cyan, stream: stream)
    sink.write("  \(tag) \(text)\n", to: stream)
  }

  /// Emits a status item (e.g. `  ✓ item: detail` or `  ✗ item`).
  package static func statusItem(
    _ symbol: String,
    label: String,
    detail: String? = nil,
    to stream: TerminalStream = .stdout
  ) {
    let styledSymbol: String
    if symbol == "✓" {
      styledSymbol = styled(symbol, color: .green, style: .bold, stream: stream)
    } else if symbol == "✗" {
      styledSymbol = styled(symbol, color: .red, style: .bold, stream: stream)
    } else {
      styledSymbol = symbol
    }

    if let detail {
      sink.write("  \(styledSymbol) \(label): \(detail)\n", to: stream)
    } else {
      sink.write("  \(styledSymbol) \(label)\n", to: stream)
    }
  }

  /// Emits an actionable hint or tip.
  package static func hint(_ text: String, to stream: TerminalStream = .stdout) {
    let prefix = styled("💡", stream: stream)
    sink.write("\(prefix) \(text)\n", to: stream)
  }
}
