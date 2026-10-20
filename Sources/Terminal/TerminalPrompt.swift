import Extensions
import Foundation

/// Errors thrown by interactive terminal prompts.
package enum TerminalPromptError: LocalizedError, Sendable {
  case nonInteractive(String)

  package var errorDescription: String? {
    switch self {
    case .nonInteractive(let question):
      return "Cannot prompt for '\(question)' in a non-interactive environment. Provide the required CLI flags."
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

  /// Prompts user to select a single option from a collection.
  package static func promptSelection<T>(
    title: String,
    options: [Option<T>],
    default defaultIndex: Int? = 0,
    customHandler: ((String) -> T?)? = nil
  ) throws -> T? {
    guard !options.isEmpty else { return nil }
    guard Terminal.isInteractive else {
      throw TerminalPromptError.nonInteractive(title)
    }
    if !title.isEmpty {
      Terminal.line("\n" + title)
    }
    for (idx, opt) in options.enumerated() {
      let ann = opt.annotation.map { " (\($0))" } ?? ""
      Terminal.numbered(idx + 1, text: "\(opt.label)\(ann)")
    }
    var promptQuestion = "Select option [1-\(options.count)]"
    var defaultVal: String?
    if let defaultIndex, options.indices.contains(defaultIndex) {
      defaultVal = "\(defaultIndex + 1)"
      promptQuestion += " (default: [\(defaultIndex + 1)] \(options[defaultIndex].label))"
    } else if customHandler != nil {
      promptQuestion += " or enter custom input (press Enter to skip)"
    }
    let choice = try prompt(question: promptQuestion, default: defaultVal)
    if let num = Int(choice), num >= 1, num <= options.count {
      return options[num - 1].value
    }
    if let customHandler, !choice.isEmpty, let customVal = customHandler(choice) {
      return customVal
    }
    return defaultIndex.flatMap { options.indices.contains($0) ? options[$0].value : nil }
  }

  /// Prompts user to select multiple options from a collection.
  package static func promptMultiSelection<T>(
    title: String,
    options: [Option<T>]
  ) throws -> [T] {
    guard !options.isEmpty else { return [] }
    guard Terminal.isInteractive else {
      throw TerminalPromptError.nonInteractive(title)
    }
    if !title.isEmpty {
      Terminal.line("\n" + title)
    }
    for (idx, opt) in options.enumerated() {
      let ann = opt.annotation.map { " (\($0))" } ?? ""
      Terminal.numbered(idx + 1, text: "\(opt.label)\(ann)")
    }
    let choice = try prompt(
      question: "Select options (comma-separated numbers, e.g. 1, 2 or press Enter to skip)",
      default: nil
    )
    guard !choice.isEmpty else { return [] }
    let numbers = choice.split(separator: ",").compactMap { Int($0.trimmed) }
    return numbers.compactMap { num in
      guard num >= 1, num <= options.count else { return nil }
      return options[num - 1].value
    }
  }
}
