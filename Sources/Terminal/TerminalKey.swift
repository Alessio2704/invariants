import Foundation

package enum TerminalKey: Equatable, Sendable {
  case up
  case down
  case space
  case enter
  case toggleAll
  case number(Int)
  case customInput
  case escape
  case ctrlC
  case unknown
}

package enum TerminalKeyDecoder: Sendable {
  package static func decode(bytes: [UInt8]) -> TerminalKey {
    guard let first = bytes.first else { return .unknown }

    if first == 0x1B {
      if bytes.count >= 3 && bytes[1] == UInt8(ascii: "[") {
        switch bytes[2] {
        case UInt8(ascii: "A"): return .up
        case UInt8(ascii: "B"): return .down
        default: return .escape
        }
      }
      return .escape
    }

    switch first {
    case 0x0A, 0x0D:
      return .enter
    case 0x20:
      return .space
    case 0x03:
      return .ctrlC
    case UInt8(ascii: "k"), UInt8(ascii: "K"):
      return .up
    case UInt8(ascii: "j"), UInt8(ascii: "J"):
      return .down
    case UInt8(ascii: "a"), UInt8(ascii: "A"):
      return .toggleAll
    case UInt8(ascii: "c"), UInt8(ascii: "C"):
      return .customInput
    case UInt8(ascii: "1")...UInt8(ascii: "9"):
      return .number(Int(first - UInt8(ascii: "0")))
    default:
      return .unknown
    }
  }
}
