import Foundation

/// Abstract input source for terminal reads.
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
