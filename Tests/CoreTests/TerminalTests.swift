import Foundation
import Terminal
import Testing

@Suite("Terminal Subsystem Tests", .tags(.unit))
struct TerminalTests {

  @Test("TerminalTestSink captures stdout and stderr independently")
  func testSinkSeparation() {
    let sink = TerminalTestSink()
    sink.write("Hello stdout\n", to: .stdout)
    sink.write("Error stderr\n", to: .stderr)

    #expect(sink.stdout == "Hello stdout\n")
    #expect(sink.stderr == "Error stderr\n")

    sink.clear()
    #expect(sink.stdout.isEmpty)
    #expect(sink.stderr.isEmpty)
  }

  @Test("Semantic error and warning channels write to stderr with proper prefixes")
  func testSemanticErrorAndWarning() {
    let sink = TerminalTestSink()
    Terminal.withSink(sink) {
      Terminal.error("Something went wrong")
      Terminal.warning("This is a caution")
    }

    #expect(sink.stdout.isEmpty)
    #expect(sink.stderr == "Error: Something went wrong\nWarning: This is a caution\n")
  }

  @Test("Semantic success and info channels write to stdout with proper formatting")
  func testSemanticSuccessAndInfo() {
    let sink = TerminalTestSink()
    Terminal.withSink(sink) {
      Terminal.success("Operation completed")
      Terminal.info("Informational detail")
      Terminal.line()
    }

    #expect(sink.stderr.isEmpty)
    #expect(sink.stdout == "✓ Operation completed\nInformational detail\n\n")
  }

  @Test("Header formatting generates title and matching divider")
  func testHeaderFormatting() {
    let sink = TerminalTestSink()
    Terminal.withSink(sink) {
      Terminal.header("Invariants Status")
    }

    let expectedDivider = String(repeating: "─", count: 17)
    #expect(sink.stdout == "Invariants Status\n\(expectedDivider)\n")
  }

  @Test("Field formatting pads labels to uniform column width")
  func testFieldFormatting() {
    let sink = TerminalTestSink()
    Terminal.withSink(sink) {
      Terminal.field("Engine", value: "1.0.0", width: 10)
      Terminal.field("Registry", value: "v1", width: 10)
    }

    #expect(sink.stdout == "Engine     1.0.0\nRegistry   v1\n")
  }

  @Test("Lists, numbered items, and status items format accurately")
  func testStructuredItems() {
    let sink = TerminalTestSink()
    Terminal.withSink(sink) {
      Terminal.item("Swift sources")
      Terminal.numbered(1, text: "First option")
      Terminal.statusItem("✓", label: "no-raw-text", detail: "active")
      Terminal.statusItem("✗", label: "forbid-eval")
      Terminal.hint("Run 'invariants check'")
    }

    #expect(sink.stdout.contains("  • Swift sources\n"))
    #expect(sink.stdout.contains("  [1] First option\n"))
    #expect(sink.stdout.contains("  ✓ no-raw-text: active\n"))
    #expect(sink.stdout.contains("  ✗ forbid-eval\n"))
    #expect(sink.stdout.contains("💡 Run 'invariants check'\n"))
  }

  @Test("withSink restores previous sink when finished")
  func testSinkRestoration() {
    let sink1 = TerminalTestSink()
    let sink2 = TerminalTestSink()

    Terminal.withSink(sink1) {
      Terminal.info("To sink 1")
      Terminal.withSink(sink2) {
        Terminal.info("To sink 2")
      }
      Terminal.info("Back to sink 1")
    }

    #expect(sink1.stdout == "To sink 1\nBack to sink 1\n")
    #expect(sink2.stdout == "To sink 2\n")
  }

  @Test("Colored semantic channels emit expected ANSI escape sequences when color is enabled")
  func testColoredSemanticChannels() {
    let sink = TerminalTestSink(allowsColor: true)
    Terminal.withSink(sink) {
      Terminal.error("Something went wrong")
      Terminal.warning("This is a caution")
      Terminal.success("Operation completed")
    }

    #expect(
      sink.stderr
        == "\u{001B}[1;31mError:\u{001B}[0m Something went wrong\n\u{001B}[1;33mWarning:\u{001B}[0m This is a caution\n"
    )
    #expect(sink.stdout == "\u{001B}[1;32m✓\u{001B}[0m Operation completed\n")
  }

  @Test("Colored structured layouts emit styled headers, numbers, and status glyphs")
  func testColoredStructuredLayouts() {
    let sink = TerminalTestSink(allowsColor: true)
    Terminal.withSink(sink) {
      Terminal.header("Status")
      Terminal.numbered(2, text: "Option two")
      Terminal.statusItem("✓", label: "rule-1", detail: "passed")
      Terminal.statusItem("✗", label: "rule-2")
    }

    #expect(sink.stdout.contains("\u{001B}[1mStatus\u{001B}[0m\n\u{001B}[90m────────────────\u{001B}[0m\n"))
    #expect(sink.stdout.contains("  \u{001B}[36m[2]\u{001B}[0m Option two\n"))
    #expect(sink.stdout.contains("  \u{001B}[1;32m✓\u{001B}[0m rule-1: passed\n"))
    #expect(sink.stdout.contains("  \u{001B}[1;31m✗\u{001B}[0m rule-2\n"))
  }

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
  }
}
