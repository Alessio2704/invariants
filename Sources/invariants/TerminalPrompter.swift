import Foundation
import InvariantCore

/// Concrete implementation of `InteractivePrompter` that interfaces with standard terminal I/O.
struct TerminalPrompter: InteractivePrompter {
  static let shared = Self()

  private init() {}

  func prompt(question: String) -> String {
    prompt(question: question, default: nil)
  }

  func prompt(question: String, default defaultValue: String?) -> String {
    if let defaultValue {
      print("\(question) [\(defaultValue)]: ", terminator: "")
    } else {
      print("\(question): ", terminator: "")
    }
    fflush(stdout)
    guard let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else {
      return defaultValue ?? ""
    }
    return line
  }

  func promptConfirmation(question: String, default defaultYes: Bool = false) -> Bool {
    let hint = defaultYes ? "[Y/n]" : "[y/N]"
    print("\(question) \(hint): ", terminator: "")
    fflush(stdout)
    guard let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
      return defaultYes
    }
    if line.isEmpty { return defaultYes }
    return line == "y" || line == "yes"
  }

  func printLine(_ message: String) {
    print(message)
  }
}
