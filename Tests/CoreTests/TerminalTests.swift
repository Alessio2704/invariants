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

    let cancelled = TerminalPromptError.cancelled
    #expect(cancelled.errorDescription == "Operation cancelled by user.")
  }

  @Test("TerminalKeyDecoder parses raw escape and ASCII key sequences")
  func testTerminalKeyDecoder() {
    #expect(TerminalKeyDecoder.decode(bytes: [0x1B, UInt8(ascii: "["), UInt8(ascii: "A")]) == .up)
    #expect(TerminalKeyDecoder.decode(bytes: [0x1B, UInt8(ascii: "["), UInt8(ascii: "B")]) == .down)
    #expect(TerminalKeyDecoder.decode(bytes: [UInt8(ascii: "k")]) == .up)
    #expect(TerminalKeyDecoder.decode(bytes: [UInt8(ascii: "j")]) == .down)
    #expect(TerminalKeyDecoder.decode(bytes: [0x20]) == .space)
    #expect(TerminalKeyDecoder.decode(bytes: [0x0A]) == .enter)
    #expect(TerminalKeyDecoder.decode(bytes: [0x0D]) == .enter)
    #expect(TerminalKeyDecoder.decode(bytes: [UInt8(ascii: "a")]) == .toggleAll)
    #expect(TerminalKeyDecoder.decode(bytes: [UInt8(ascii: "1")]) == .number(1))
    #expect(TerminalKeyDecoder.decode(bytes: [UInt8(ascii: "2")]) == .number(2))
    #expect(TerminalKeyDecoder.decode(bytes: [0x03]) == .ctrlC)
    #expect(TerminalKeyDecoder.decode(bytes: [0x1B]) == .escape)
    #expect(TerminalKeyDecoder.decode(bytes: []) == .unknown)
  }

  @Test("MultiSelectEngine handles navigation, space toggling, select-all, and numbers")
  func testMultiSelectEngine() {
    let options = [
      TerminalPrompt.Option(value: "swift", label: "Swift", annotation: "extensions: .swift"),
      TerminalPrompt.Option(value: "ts", label: "TypeScript", annotation: "extensions: .ts"),
      TerminalPrompt.Option(value: "go", label: "Go", annotation: "extensions: .go"),
    ]

    var engine = MultiSelectEngine(title: "Select languages", options: options)
    #expect(engine.cursorIndex == 0)
    #expect(engine.selectedIndices.isEmpty)

    // Down moves to index 1
    _ = engine.handleKey(.down)
    #expect(engine.cursorIndex == 1)

    // Space toggles index 1
    _ = engine.handleKey(.space)
    #expect(engine.selectedIndices == [1])

    // Down moves to index 2
    _ = engine.handleKey(.down)
    #expect(engine.cursorIndex == 2)

    // Space toggles index 2
    _ = engine.handleKey(.space)
    #expect(engine.selectedIndices == [1, 2])

    // Down wraps to index 0
    _ = engine.handleKey(.down)
    #expect(engine.cursorIndex == 0)

    // Up wraps to index 2
    _ = engine.handleKey(.up)
    #expect(engine.cursorIndex == 2)

    // Number jump toggles index 0
    _ = engine.handleKey(.number(1))
    #expect(engine.selectedIndices == [0, 1, 2])

    // ToggleAll deselects all when everything is selected
    _ = engine.handleKey(.toggleAll)
    #expect(engine.selectedIndices.isEmpty)

    // ToggleAll selects all when empty
    _ = engine.handleKey(.toggleAll)
    #expect(engine.selectedIndices == [0, 1, 2])

    // Space toggles off index 0 (since number(1) moved cursor to 0)
    _ = engine.handleKey(.space)
    #expect(engine.selectedIndices == [1, 2])

    // Enter submits selected in option order
    if case .submit(let selected) = engine.handleKey(.enter) {
      #expect(selected == ["ts", "go"])
    } else {
      Issue.record("Expected .submit")
    }

    // Escape cancels
    if case .cancel = engine.handleKey(.escape) {
      // success
    } else {
      Issue.record("Expected .cancel")
    }
  }

  @Test("MultiSelectEngine renderLines produces modern arrows and bullets")
  func testMultiSelectRendering() {
    let options = [
      TerminalPrompt.Option(value: "swift", label: "Swift", annotation: ".swift"),
      TerminalPrompt.Option(value: "ts", label: "TypeScript", annotation: ".ts"),
    ]

    var engine = MultiSelectEngine(title: "Choose languages", options: options)
    _ = engine.handleKey(.space)  // select swift

    let lines = engine.renderLines()
    let text = lines.joined(separator: "\n")

    #expect(text.contains("?"))
    #expect(text.contains("Choose languages"))
    #expect(text.contains("↑/↓ navigate"))
    #expect(text.contains("❯"))  // Active pointer on Swift
    #expect(text.contains("●"))  // Filled bullet on Swift
    #expect(text.contains("○"))  // Empty bullet on TypeScript
  }

  @Test("SingleSelectEngine handles arrow navigation and submission")
  func testSingleSelectEngine() {
    let options = [
      TerminalPrompt.Option(value: "main", label: "main"),
      TerminalPrompt.Option(value: "develop", label: "develop"),
    ]

    var engine = SingleSelectEngine(title: "Select branch", options: options, defaultIndex: 0)
    #expect(engine.cursorIndex == 0)

    _ = engine.handleKey(.down)
    #expect(engine.cursorIndex == 1)

    let lines = engine.renderLines()
    let text = lines.joined(separator: "\n")
    #expect(text.contains("❯"))
    #expect(text.contains("●"))

    if case .submit(let branch) = engine.handleKey(.enter) {
      #expect(branch == "develop")
    } else {
      Issue.record("Expected .submit")
    }

    // Test custom input request
    var customEngine = SingleSelectEngine(title: "Branch", options: options, hasCustomHandler: true)
    let customLines = customEngine.renderLines()
    #expect(customLines.joined(separator: "\n").contains("c custom"))

    if case .customInputRequested = customEngine.handleKey(.customInput) {
      // success
    } else {
      Issue.record("Expected .customInputRequested")
    }
  }

  @Test("Terminal interactive query executes without crashing")
  func testTerminalIsInteractive() {
    _ = Terminal.isInteractive
  }
}
