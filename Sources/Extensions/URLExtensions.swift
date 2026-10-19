public import Foundation

extension URL {
  /// Reads the UTF-8 text content of the file at this URL.
  public func readUTF8() throws -> String {
    try String(contentsOf: self, encoding: .utf8)
  }

  /// Reads the UTF-8 text content of the file at this URL, trimmed of leading and trailing whitespace and newlines.
  public func readTrimmedUTF8() throws -> String {
    try readUTF8().trimmed
  }
}
