import Foundation

/// Fast glob pattern matcher for scopes.
public struct GlobMatcher: Sendable {
  private let regex: NSRegularExpression

  public init?(pattern: String) {
    var p = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    if p.hasPrefix("./") {
      p = String(p.dropFirst(2))
    }

    // Convert glob pattern to regular expression
    var regexStr = "^"
    var i = p.startIndex
    let specialChars: Set<Character> = [".", "(", ")", "+", "|", "^", "$", "{", "}", "[", "]", "\\"]
    while i < p.endIndex {
      let ch = p[i]
      if ch == "*" {
        let nextIdx = p.index(after: i)
        if nextIdx < p.endIndex && p[nextIdx] == "*" {
          // "**"
          let afterNext = p.index(after: nextIdx)
          if afterNext < p.endIndex && p[afterNext] == "/" {
            // "**/": matches zero or more directories
            regexStr.append("(?:.*/)?")
            i = p.index(after: afterNext)
            continue
          } else {
            regexStr.append(".*")
            i = afterNext
            continue
          }
        } else {
          // Single "*" matches anything except path separator
          regexStr.append("[^/]*")
          i = nextIdx
          continue
        }
      } else if ch == "?" {
        regexStr.append("[^/]")
      } else if specialChars.contains(ch) {
        regexStr.append("\\\(ch)")
      } else {
        regexStr.append(ch)
      }
      i = p.index(after: i)
    }
    regexStr.append("$")

    guard let reg = try? NSRegularExpression(pattern: regexStr, options: []) else {
      return nil
    }
    self.regex = reg
  }

  public func matches(_ relativePath: String) -> Bool {
    var path = relativePath
    if path.hasPrefix("./") {
      path = String(path.dropFirst(2))
    }
    let range = NSRange(location: 0, length: path.utf16.count)
    return regex.firstMatch(in: path, options: [], range: range) != nil
  }
}
