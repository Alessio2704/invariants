import Foundation

/// An interactive item option with value, label, and optional annotation.
public struct PromptOption<T: Sendable>: Sendable {
  public let value: T
  public let label: String
  public let annotation: String?

  public init(value: T, label: String, annotation: String? = nil) {
    self.value = value
    self.label = label
    self.annotation = annotation
  }
}

/// Interactive prompter interface for user input during CLI commands.
public protocol InteractivePrompter: Sendable {
  func prompt(question: String) -> String
  func prompt(question: String, default defaultValue: String?) -> String
  func promptConfirmation(question: String, default defaultYes: Bool) -> Bool
  func printLine(_ message: String)

  func promptSelection<T: Sendable>(
    title: String,
    options: [PromptOption<T>],
    default defaultOptionIndex: Int?,
    customHandler: ((String) -> T?)?
  ) -> T?

  func promptMultiSelection<T: Sendable>(
    title: String,
    options: [PromptOption<T>]
  ) -> [T]
}

extension InteractivePrompter {
  public func prompt(question: String) -> String {
    prompt(question: question, default: nil)
  }

  public func promptSelection<T: Sendable>(
    title: String,
    options: [PromptOption<T>],
    default defaultOptionIndex: Int? = 0,
    customHandler: ((String) -> T?)? = nil
  ) -> T? {
    guard !options.isEmpty else { return nil }
    if !title.isEmpty {
      printLine("\n" + title)
    }
    for (idx, opt) in options.enumerated() {
      let ann = opt.annotation.map { " (\($0))" } ?? ""
      printLine("  [\(idx + 1)] \(opt.label)\(ann)")
    }
    var promptQuestion = "Select option [1-\(options.count)]"
    var defaultVal: String?
    if let defaultOptionIndex, options.indices.contains(defaultOptionIndex) {
      defaultVal = "\(defaultOptionIndex + 1)"
      promptQuestion += " (default: [\(defaultOptionIndex + 1)] \(options[defaultOptionIndex].label))"
    } else if customHandler != nil {
      promptQuestion += " or enter custom input (press Enter to skip)"
    }
    let choice = prompt(question: promptQuestion, default: defaultVal)
    if let num = Int(choice), num >= 1, num <= options.count {
      return options[num - 1].value
    }
    if let customHandler, !choice.isEmpty, let customVal = customHandler(choice) {
      return customVal
    }
    return defaultOptionIndex.flatMap { options.indices.contains($0) ? options[$0].value : nil }
  }

  public func promptMultiSelection<T: Sendable>(
    title: String,
    options: [PromptOption<T>]
  ) -> [T] {
    guard !options.isEmpty else { return [] }
    if !title.isEmpty {
      printLine("\n" + title)
    }
    for (idx, opt) in options.enumerated() {
      let ann = opt.annotation.map { " (\($0))" } ?? ""
      printLine("  [\(idx + 1)] \(opt.label)\(ann)")
    }
    let choice = prompt(
      question: "Select options (comma-separated numbers, e.g. 1, 2 or press Enter to skip)",
      default: nil
    )
    guard !choice.isEmpty else { return [] }
    let numbers = choice.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    return numbers.compactMap { num in
      guard num >= 1, num <= options.count else { return nil }
      return options[num - 1].value
    }
  }
}
