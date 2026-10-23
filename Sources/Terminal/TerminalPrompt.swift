import Extensions
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Errors thrown by interactive terminal prompts.
package enum TerminalPromptError: LocalizedError, Sendable {
  case nonInteractive(String)
  case cancelled

  package var errorDescription: String? {
    switch self {
    case .nonInteractive(let question):
      return "Cannot prompt for '\(question)' in a non-interactive environment. Provide the required CLI flags."
    case .cancelled:
      return "Operation cancelled by user."
    }
  }
}

/// Generic interactive terminal I/O primitives for CLI applications.
package enum TerminalPrompt {
  /// Prompts user for a single line of input with an optional default value on Enter.
  package static func prompt(
    question: String,
    default defaultValue: String? = nil
  ) throws -> String {
    guard Terminal.isInteractive else {
      throw TerminalPromptError.nonInteractive(question)
    }
    if let defaultValue {
      let styledDefault = Terminal.styled("[\(defaultValue)]", color: .gray)
      Terminal.write("\(question) \(styledDefault): ", to: .stdout)
    } else {
      Terminal.write("\(question): ", to: .stdout)
    }
    guard let line = Terminal.readLine()?.trimmed, !line.isEmpty else {
      return defaultValue ?? ""
    }
    return line
  }

  /// Prompts user for a yes/no confirmation.
  package static func promptConfirmation(
    question: String,
    default defaultYes: Bool = false
  ) throws -> Bool {
    guard Terminal.isInteractive else {
      throw TerminalPromptError.nonInteractive(question)
    }
    let hint = defaultYes ? "[Y/n]" : "[y/N]"
    let styledHint = Terminal.styled(hint, color: .gray)
    Terminal.write("\(question) \(styledHint): ", to: .stdout)
    guard let line = Terminal.readLine()?.trimmed.lowercased(), !line.isEmpty else {
      return defaultYes
    }
    return line == "y" || line == "yes"
  }

  package struct Option<T>: Sendable where T: Sendable {
    package let value: T
    package let label: String
    package let annotation: String?

    package init(value: T, label: String, annotation: String? = nil) {
      self.value = value
      self.label = label
      self.annotation = annotation
    }
  }

  /// Prompts user to select a single option from a collection using modern interactive arrow navigation.
  package static func promptSelection<T: Sendable>(
    title: String,
    options: [Option<T>],
    default defaultIndex: Int? = 0,
    customHandler: ((String) -> T?)? = nil
  ) throws -> T? {
    guard !options.isEmpty else { return nil }
    guard Terminal.isInteractive else {
      if let defaultIndex, options.indices.contains(defaultIndex) {
        return options[defaultIndex].value
      }
      throw TerminalPromptError.nonInteractive(title)
    }

    var engine = SingleSelectEngine(
      title: title,
      options: options,
      defaultIndex: defaultIndex ?? 0,
      hasCustomHandler: customHandler != nil
    )
    let session = RawTerminalSession()
    defer { session.restore() }

    var renderedLineCount = 0

    while true {
      let lines = engine.renderLines()
      if renderedLineCount > 0 {
        Terminal.write("\u{001B}[\(renderedLineCount)A\u{001B}[0J", to: .stdout)
      }
      for line in lines {
        Terminal.line(line)
      }
      renderedLineCount = lines.count

      let key = session.readKey()
      switch engine.handleKey(key) {
      case .continue:
        continue
      case .submit(let selected):
        if renderedLineCount > 0 {
          Terminal.write("\u{001B}[\(renderedLineCount)A\u{001B}[0J", to: .stdout)
        }
        session.restore()
        let checkmark = Terminal.styled("✔", color: .green, style: .bold)
        let selectedLabel = options[engine.cursorIndex].label
        let cleanTitle = title.trimmingCharacters(in: CharacterSet(charactersIn: ":? "))
        Terminal.line("\(checkmark) \(cleanTitle): \(Terminal.styled(selectedLabel, color: .white, style: .bold))")
        return selected
      case .customInputRequested:
        if renderedLineCount > 0 {
          Terminal.write("\u{001B}[\(renderedLineCount)A\u{001B}[0J", to: .stdout)
        }
        session.restore()
        if let customHandler {
          let typed = try prompt(question: "Enter custom value")
          if !typed.isEmpty, let customVal = customHandler(typed) {
            let checkmark = Terminal.styled("✔", color: .green, style: .bold)
            let cleanTitle = title.trimmingCharacters(in: CharacterSet(charactersIn: ":? "))
            Terminal.line("\(checkmark) \(cleanTitle): \(Terminal.styled(typed, color: .white, style: .bold))")
            return customVal
          }
        }
        return nil
      case .cancel:
        if renderedLineCount > 0 {
          Terminal.write("\u{001B}[\(renderedLineCount)A\u{001B}[0J", to: .stdout)
        }
        session.restore()
        throw TerminalPromptError.cancelled
      }
    }
  }

  /// Prompts user to select multiple options from a collection using interactive arrow navigation and Space toggling.
  package static func promptMultiSelection<T: Sendable>(
    title: String,
    options: [Option<T>],
    preselectedIndices: Set<Int> = []
  ) throws -> [T] {
    guard !options.isEmpty else { return [] }
    guard Terminal.isInteractive else {
      throw TerminalPromptError.nonInteractive(title)
    }

    var engine = MultiSelectEngine(title: title, options: options, preselectedIndices: preselectedIndices)
    let session = RawTerminalSession()
    defer { session.restore() }

    var renderedLineCount = 0

    while true {
      let lines = engine.renderLines()
      if renderedLineCount > 0 {
        Terminal.write("\u{001B}[\(renderedLineCount)A\u{001B}[0J", to: .stdout)
      }
      for line in lines {
        Terminal.line(line)
      }
      renderedLineCount = lines.count

      let key = session.readKey()
      switch engine.handleKey(key) {
      case .continue, .customInputRequested:
        continue
      case .submit(let selected):
        if renderedLineCount > 0 {
          Terminal.write("\u{001B}[\(renderedLineCount)A\u{001B}[0J", to: .stdout)
        }
        session.restore()
        let checkmark = Terminal.styled("✔", color: .green, style: .bold)
        let selectedLabels = options.indices
          .filter { engine.selectedIndices.contains($0) }
          .map { options[$0].label }
          .joined(separator: ", ")
        let cleanTitle = title.trimmingCharacters(in: CharacterSet(charactersIn: ":? "))
        let displayResult = selectedLabels.isEmpty ? "none" : selectedLabels
        Terminal.line("\(checkmark) \(cleanTitle): \(Terminal.styled(displayResult, color: .white, style: .bold))")
        return selected
      case .cancel:
        if renderedLineCount > 0 {
          Terminal.write("\u{001B}[\(renderedLineCount)A\u{001B}[0J", to: .stdout)
        }
        session.restore()
        throw TerminalPromptError.cancelled
      }
    }
  }
}

package final class RawTerminalSession {
  private var originalTermios = termios()
  private var isRaw = false

  package init() {
    guard Terminal.isInteractive else { return }
    if tcgetattr(STDIN_FILENO, &originalTermios) == 0 {
      var raw = originalTermios
      raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
      if tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 {
        isRaw = true
        Terminal.write("\u{001B}[?25l", to: .stdout)
      }
    }
  }

  package func restore() {
    guard isRaw else { return }
    Terminal.write("\u{001B}[?25h", to: .stdout)
    tcsetattr(STDIN_FILENO, TCSANOW, &originalTermios)
    isRaw = false
  }

  package func readKey() -> TerminalKey {
    var firstByte: UInt8 = 0
    let bytesRead = read(STDIN_FILENO, &firstByte, 1)
    guard bytesRead > 0 else { return .unknown }

    var bytes: [UInt8] = [firstByte]

    if firstByte == 0x1B {
      var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
      if poll(&pfd, 1, 50) > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
        var secondByte: UInt8 = 0
        if read(STDIN_FILENO, &secondByte, 1) > 0 {
          bytes.append(secondByte)
          if secondByte == UInt8(ascii: "[") {
            if poll(&pfd, 1, 50) > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
              var thirdByte: UInt8 = 0
              if read(STDIN_FILENO, &thirdByte, 1) > 0 {
                bytes.append(thirdByte)
                while poll(&pfd, 1, 10) > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
                  var extraByte: UInt8 = 0
                  if read(STDIN_FILENO, &extraByte, 1) > 0 {
                    bytes.append(extraByte)
                  } else {
                    break
                  }
                }
              }
            }
          }
        }
      }
    }

    return TerminalKeyDecoder.decode(bytes: bytes)
  }

  deinit {
    restore()
  }
}
