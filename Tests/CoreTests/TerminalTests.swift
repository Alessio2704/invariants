import Foundation
import Terminal
import Testing

@Suite("Terminal Subsystem Tests", .tags(.unit))
struct TerminalTests {

  @Test("stripANSI removes escape codes and preserves plain content")
  func testStripANSI() {
    let raw = "\u{001B}[1;31mError:\u{001B}[0m \u{001B}[32m✓\u{001B}[0m plain text"
    #expect(Terminal.stripANSI(raw) == "Error: ✓ plain text")
    #expect(Terminal.stripANSI("already clean") == "already clean")
  }

  @Test("All TerminalColor and TerminalStyle enum values format to exact ANSI codes")
  func testAllColorsAndStyles() {
    let colors: [TerminalColor] = [
      .black, .red, .green, .yellow, .blue, .magenta, .cyan, .white, .gray,
    ]
    let expectedCodes = [30, 31, 32, 33, 34, 35, 36, 37, 90]

    for (color, expected) in zip(colors, expectedCodes) {
      #expect(color.rawCode == expected)
      let formatted = Terminal.format("test", color: color)
      #expect(formatted == "\u{001B}[\(expected)mtest\u{001B}[0m")
    }

    let styles: [TerminalStyle] = [.bold, .dim, .italic, .underline]
    let expectedStyleCodes = [1, 2, 3, 4]

    for (style, expected) in zip(styles, expectedStyleCodes) {
      #expect(style.rawCode == expected)
      let formatted = Terminal.format("test", style: style)
      #expect(formatted == "\u{001B}[\(expected)mtest\u{001B}[0m")
    }
  }

  @Test("environmentSupportsColor correctly honors standard environment variables")
  func testEnvironmentSupportsColor() {
    // 1. CLICOLOR_FORCE forces color regardless of TTY or NO_COLOR
    #expect(
      Terminal.environmentSupportsColor(
        for: .stdout,
        environment: ["CLICOLOR_FORCE": "1", "NO_COLOR": "1"],
        isTTY: false
      )
    )

    // 2. NO_COLOR disables color
    #expect(
      !Terminal.environmentSupportsColor(
        for: .stdout,
        environment: ["NO_COLOR": "1"],
        isTTY: true
      )
    )

    // 3. CLICOLOR=0 disables color
    #expect(
      !Terminal.environmentSupportsColor(
        for: .stdout,
        environment: ["CLICOLOR": "0"],
        isTTY: true
      )
    )

    // 4. TERM=dumb disables color
    #expect(
      !Terminal.environmentSupportsColor(
        for: .stdout,
        environment: ["TERM": "dumb"],
        isTTY: true
      )
    )

    // 5. Without overrides, respects isTTY
    #expect(
      Terminal.environmentSupportsColor(
        for: .stdout,
        environment: [:],
        isTTY: true
      )
    )
    #expect(
      !Terminal.environmentSupportsColor(
        for: .stdout,
        environment: [:],
        isTTY: false
      )
    )

    // 6. Test default overload reading TTY from file descriptor
    _ = Terminal.environmentSupportsColor(for: .stdout)
    _ = Terminal.supportsColor(for: .stdout)
    _ = Terminal.supportsColor(for: .stderr)
  }

  @Test("TerminalPromptError produces clear localized error description")
  func testTerminalPromptErrorDescription() {
    let error = TerminalPromptError.nonInteractive("Confirm deletion")
    #expect(error.errorDescription?.contains("Cannot prompt for 'Confirm deletion'") == true)
    #expect(error.errorDescription?.contains("non-interactive environment") == true)
  }

  @Test("Terminal interactive query executes without crashing")
  func testTerminalIsInteractive() {
    _ = Terminal.isInteractive
  }
}
