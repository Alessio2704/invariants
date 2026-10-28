import Extensions
import Foundation

package enum EngineResult<T: Sendable>: Sendable {
  case `continue`
  case submit(T)
  case customInputRequested
  case cancel
}

package struct MultiSelectEngine<T: Sendable>: Sendable {
  package let title: String
  package let options: [TerminalPrompt.Option<T>]
  package var cursorIndex: Int = 0
  package var selectedIndices: Set<Int> = []

  package init(title: String, options: [TerminalPrompt.Option<T>], preselectedIndices: Set<Int> = []) {
    self.title = title
    self.options = options
    self.cursorIndex = 0
    self.selectedIndices = preselectedIndices
  }

  package mutating func handleKey(_ key: TerminalKey) -> EngineResult<[T]> {
    switch key {
    case .up:
      if cursorIndex > 0 {
        cursorIndex -= 1
      } else {
        cursorIndex = max(0, options.count - 1)
      }
      return .continue
    case .down:
      if cursorIndex < options.count - 1 {
        cursorIndex += 1
      } else {
        cursorIndex = 0
      }
      return .continue
    case .space:
      if options.indices.contains(cursorIndex) {
        if selectedIndices.contains(cursorIndex) {
          selectedIndices.remove(cursorIndex)
        } else {
          selectedIndices.insert(cursorIndex)
        }
      }
      return .continue
    case .right:
      if options.indices.contains(cursorIndex) {
        selectedIndices.insert(cursorIndex)
      }
      return .continue
    case .left:
      if options.indices.contains(cursorIndex) {
        selectedIndices.remove(cursorIndex)
      }
      return .continue
    case .toggleAll:
      if selectedIndices.count == options.count {
        selectedIndices.removeAll()
      } else {
        selectedIndices = Set(options.indices)
      }
      return .continue
    case .number(let n):
      let idx = n - 1
      if options.indices.contains(idx) {
        cursorIndex = idx
        if selectedIndices.contains(idx) {
          selectedIndices.remove(idx)
        } else {
          selectedIndices.insert(idx)
        }
      }
      return .continue
    case .enter:
      let sortedSelected = options.indices.filter { selectedIndices.contains($0) }.map { options[$0].value }
      return .submit(sortedSelected)
    case .escape, .ctrlC, .eof:
      return .cancel
    default:
      return .continue
    }
  }

  package func renderLines() -> [String] {
    var lines: [String] = []
    if !title.isEmpty {
      let promptPrefix = Terminal.styled("?", color: .cyan, style: .bold)
      lines.append("\(promptPrefix) \(Terminal.styled(title, style: .bold))")
      lines.append("  " + Terminal.styled("↑/↓ navigate • space toggle • a all • enter confirm", color: .gray))
    }

    for (idx, opt) in options.enumerated() {
      let isFocused = (idx == cursorIndex)
      let isSelected = selectedIndices.contains(idx)

      let pointer = isFocused ? Terminal.styled("❯", color: .cyan, style: .bold) : " "
      let bullet =
        isSelected
        ? Terminal.styled("●", color: .cyan, style: .bold)
        : Terminal.styled("○", color: .gray)

      let label =
        isFocused
        ? Terminal.styled(opt.label, color: .white, style: .bold)
        : opt.label

      let ann = opt.annotation.map { " " + Terminal.styled("(\($0))", color: .gray) } ?? ""

      lines.append("\(pointer) \(bullet) \(label)\(ann)")
    }
    return lines
  }
}

package struct SingleSelectEngine<T: Sendable>: Sendable {
  package let title: String
  package let options: [TerminalPrompt.Option<T>]
  package var cursorIndex: Int
  package let hasCustomHandler: Bool

  package init(
    title: String,
    options: [TerminalPrompt.Option<T>],
    defaultIndex: Int = 0,
    hasCustomHandler: Bool = false
  ) {
    self.title = title
    self.options = options
    self.cursorIndex = options.indices.contains(defaultIndex) ? defaultIndex : 0
    self.hasCustomHandler = hasCustomHandler
  }

  package mutating func handleKey(_ key: TerminalKey) -> EngineResult<T> {
    switch key {
    case .up:
      if cursorIndex > 0 {
        cursorIndex -= 1
      } else {
        cursorIndex = max(0, options.count - 1)
      }
      return .continue
    case .down:
      if cursorIndex < options.count - 1 {
        cursorIndex += 1
      } else {
        cursorIndex = 0
      }
      return .continue
    case .number(let n):
      let idx = n - 1
      if options.indices.contains(idx) {
        cursorIndex = idx
      }
      return .continue
    case .customInput:
      if hasCustomHandler {
        return .customInputRequested
      }
      return .continue
    case .enter:
      guard options.indices.contains(cursorIndex) else { return .cancel }
      return .submit(options[cursorIndex].value)
    case .escape, .ctrlC, .eof:
      return .cancel
    default:
      return .continue
    }
  }

  package func renderLines() -> [String] {
    var lines: [String] = []
    if !title.isEmpty {
      let promptPrefix = Terminal.styled("?", color: .cyan, style: .bold)
      lines.append("\(promptPrefix) \(Terminal.styled(title, style: .bold))")
      let hint =
        hasCustomHandler
        ? "↑/↓ navigate • c custom • enter confirm"
        : "↑/↓ navigate • enter confirm"
      lines.append("  " + Terminal.styled(hint, color: .gray))
    }

    for (idx, opt) in options.enumerated() {
      let isFocused = (idx == cursorIndex)

      let pointer = isFocused ? Terminal.styled("❯", color: .cyan, style: .bold) : " "
      let bullet =
        isFocused
        ? Terminal.styled("●", color: .cyan, style: .bold)
        : Terminal.styled("○", color: .gray)

      let label =
        isFocused
        ? Terminal.styled(opt.label, color: .white, style: .bold)
        : opt.label

      let ann = opt.annotation.map { " " + Terminal.styled("(\($0))", color: .gray) } ?? ""

      lines.append("\(pointer) \(bullet) \(label)\(ann)")
    }
    return lines
  }
}
