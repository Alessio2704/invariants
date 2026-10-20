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
}
