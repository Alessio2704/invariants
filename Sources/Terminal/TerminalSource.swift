import Foundation

/// Abstract input source for terminal reads, allowing in-memory simulation in tests.
package protocol TerminalSource: Sendable {
  func readLine() -> String?
  var isInteractive: Bool { get }
}

/// Standard native terminal input source reading directly from stdin.
package struct StandardTerminalSource: TerminalSource {
  package init() {}

  package func readLine() -> String? {
    Swift.readLine()
  }

  package var isInteractive: Bool {
    isatty(FileHandle.standardInput.fileDescriptor) != 0
  }
}

/// Thread-safe in-memory input source for feeding simulated inputs in automated tests.
package final class TerminalTestSource: TerminalSource, @unchecked Sendable {
  private let lock = NSLock()
  private var inputs: [String]
  package var isInteractive: Bool

  package init(inputs: [String] = [], isInteractive: Bool = true) {
    self.inputs = inputs
    self.isInteractive = isInteractive
  }

  package func readLine() -> String? {
    lock.lock()
    defer { lock.unlock() }
    guard !inputs.isEmpty else { return nil }
    return inputs.removeFirst()
  }

  package func enqueue(_ input: String) {
    lock.lock()
    defer { lock.unlock() }
    inputs.append(input)
  }
}
