import Foundation

extension String {
  /// Returns this string with leading and trailing whitespace and newlines removed.
  public var trimmed: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

extension Substring {
  /// Returns this substring as a String with leading and trailing whitespace and newlines removed.
  public var trimmed: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
