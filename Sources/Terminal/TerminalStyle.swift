/// Standard ANSI colors for terminal output styling.
package enum TerminalColor: Sendable {
  case black
  case red
  case green
  case yellow
  case blue
  case magenta
  case cyan
  case white
  case gray

  package var rawCode: Int {
    switch self {
    case .black: return 30
    case .red: return 31
    case .green: return 32
    case .yellow: return 33
    case .blue: return 34
    case .magenta: return 35
    case .cyan: return 36
    case .white: return 37
    case .gray: return 90
    }
  }
}

/// Standard ANSI text styles for terminal output styling.
package enum TerminalStyle: Sendable {
  case bold
  case dim
  case italic
  case underline

  package var rawCode: Int {
    switch self {
    case .bold: return 1
    case .dim: return 2
    case .italic: return 3
    case .underline: return 4
    }
  }
}
