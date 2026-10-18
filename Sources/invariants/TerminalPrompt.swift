import Foundation
import InvariantCore

/// Utilities for interactive terminal prompts in CLI commands.
enum TerminalPrompt {
  /// Whether current process standard input is an interactive terminal.
  static var isInteractive: Bool {
    isatty(FileHandle.standardInput.fileDescriptor) != 0
  }

  /// Prompts user for a single line of input with an optional default value.
  static func prompt(question: String, default defaultValue: String? = nil) -> String {
    guard isInteractive else { return defaultValue ?? "" }
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

  /// Prompts user for a yes/no confirmation.
  static func promptConfirmation(question: String, default defaultYes: Bool = false) -> Bool {
    guard isInteractive else { return defaultYes }
    let hint = defaultYes ? "[Y/n]" : "[y/N]"
    print("\(question) \(hint): ", terminator: "")
    fflush(stdout)
    guard let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
      return defaultYes
    }
    if line.isEmpty { return defaultYes }
    return line == "y" || line == "yes"
  }

  struct Option<T> {
    let value: T
    let label: String
    let annotation: String?

    init(value: T, label: String, annotation: String? = nil) {
      self.value = value
      self.label = label
      self.annotation = annotation
    }
  }

  /// Prompts user to select a single option from a list.
  static func promptSelection<T>(
    title: String,
    options: [Option<T>],
    default defaultIndex: Int? = 0,
    customHandler: ((String) -> T?)? = nil
  ) -> T? {
    guard !options.isEmpty else { return nil }
    guard isInteractive else {
      return defaultIndex.flatMap { options.indices.contains($0) ? options[$0].value : nil }
    }
    if !title.isEmpty {
      print("\n" + title)
    }
    for (idx, opt) in options.enumerated() {
      let ann = opt.annotation.map { " (\($0))" } ?? ""
      print("  [\(idx + 1)] \(opt.label)\(ann)")
    }
    var promptQuestion = "Select option [1-\(options.count)]"
    var defaultVal: String?
    if let defaultIndex, options.indices.contains(defaultIndex) {
      defaultVal = "\(defaultIndex + 1)"
      promptQuestion += " (default: [\(defaultIndex + 1)] \(options[defaultIndex].label))"
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
    return defaultIndex.flatMap { options.indices.contains($0) ? options[$0].value : nil }
  }

  /// Prompts user to select multiple options from a list.
  static func promptMultiSelection<T>(
    title: String,
    options: [Option<T>]
  ) -> [T] {
    guard !options.isEmpty && isInteractive else { return [] }
    if !title.isEmpty {
      print("\n" + title)
    }
    for (idx, opt) in options.enumerated() {
      let ann = opt.annotation.map { " (\($0))" } ?? ""
      print("  [\(idx + 1)] \(opt.label)\(ann)")
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

  /// Prompts user to resolve or generate a signing key if needed.
  static func promptForSigningKey(customPath: String? = nil) async -> URL? {
    if let resolved = SigningKeyResolver.resolveSigningKey(customPath: customPath) {
      return resolved
    }

    guard isInteractive else {
      return nil
    }

    let shouldGenerate = promptConfirmation(
      question: "Signing key not found at ~/\(SystemPaths.defaultKeySubpath). Generate a Touch ID hardware key now?",
      default: true
    )
    if shouldGenerate {
      do {
        print("Touch your Touch ID sensor to enroll your hardware signing key in Apple Secure Enclave...")
        let key = try await SigningKeyResolver.generateHardwareKey(force: false)
        let pubURL = key.appendingPathExtension("pub")
        let pubStr = (try? String(contentsOf: pubURL, encoding: .utf8))?
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if let pubKey = pubStr, !pubKey.isEmpty {
          print("✓ Created Apple Secure Enclave P-256 signing key: \(key.path)")
          print("✓ Protected by Touch ID biometric hardware authorization\n")
          print("Public Key:\n  \(pubKey)\n")
        }
        return key
      } catch {
        fputs("Warning: Could not generate Secure Enclave key: \(error)\n", stderr)
      }
    }

    let custom = prompt(
      question: "Enter path to an existing SSH private key (or press Enter to cancel)"
    )
    if !custom.isEmpty {
      let expanded = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
      if FileManager.default.fileExists(atPath: expanded.path) {
        return expanded
      }
    }

    return nil
  }
}
