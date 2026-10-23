public import Foundation
import SwiftParser
public import SwiftSyntax

/// Represents a Swift source file with its syntax tree and location converter.
public struct SourceFile: Sendable {
  /// Absolute URL of the file.
  public let url: URL

  /// Path relative to the repository root.
  public let relativePath: String

  /// Source code text.
  public let sourceText: String

  /// Parsed SwiftSyntax tree.
  public let syntax: SourceFileSyntax

  /// Source location converter for line/column translation.
  public let converter: SourceLocationConverter

  /// Initializes a SourceFile.
  public init(url: URL, repoRoot: URL) {
    self.url = url
    let rootPath = repoRoot.standardizedFileURL.path
    let filePath = url.standardizedFileURL.path
    if filePath.hasPrefix(rootPath) {
      var rel = String(filePath.dropFirst(rootPath.count))
      if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
      self.relativePath = rel
    } else {
      self.relativePath = url.lastPathComponent
    }

    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    self.sourceText = text
    let syn = Parser.parse(source: text)
    self.syntax = syn
    self.converter = SourceLocationConverter(fileName: url.path, tree: syn)
  }
}

/// Collection of Swift source files supporting fluent queries.
public struct SourceFileCollection: Sendable {
  /// In-scope source files.
  public let files: [SourceFile]

  /// Initializes a collection from file URLs.
  public init(files: [URL], repoRoot: URL) {
    self.files =
      files
      .filter { $0.pathExtension == "swift" }
      .map { SourceFile(url: $0, repoRoot: repoRoot) }
  }

  /// Queries function and initializer calls by callee name.
  public func calls(named names: String...) -> CallQuery {
    calls(named: names)
  }

  /// Queries function and initializer calls by callee name array.
  public func calls(named names: [String]) -> CallQuery {
    let nameSet = Set(names)
    var matches: [CallMatch] = []

    for file in files {
      let visitor = FunctionCallVisitor(targetNames: nameSet, file: file)
      visitor.walk(file.syntax)
      matches.append(contentsOf: visitor.matches)
    }
    return CallQuery(matches: matches)
  }

  /// Queries all string literals in the source files.
  public var stringLiterals: [StringLiteralMatch] {
    var results: [StringLiteralMatch] = []
    for file in files {
      let visitor = StringLiteralVisitor(file: file)
      visitor.walk(file.syntax)
      results.append(contentsOf: visitor.matches)
    }
    return results
  }
}

/// Kind of argument expression to filter for.
public enum ArgumentKind: Sendable, Equatable {
  /// Argument is a string literal.
  case stringLiteral
  /// Argument is an empty string literal.
  case emptyString
}

/// Represents a matched function or initializer call.
public struct CallMatch: Sendable {
  /// Name of the callee.
  public let callee: String
  /// The containing source file.
  public let file: SourceFile
  /// The 1-indexed line number.
  public let line: Int
  /// The 1-indexed column number.
  public let column: Int
  /// Text of the first argument if it is a string literal.
  public let firstArgumentStringValue: String?
  /// Raw snippet of the first argument.
  public let argumentSnippet: String

  /// Relative file path.
  public var relativePath: String {
    file.relativePath
  }
}

/// Fluent query builder for call expressions.
public struct CallQuery: Sendable {
  /// Current matched calls.
  public let matches: [CallMatch]

  /// Initializes a CallQuery with matches.
  public init(matches: [CallMatch]) {
    self.matches = matches
  }

  /// Filters calls where the first argument matches the given kind.
  public func whereFirstArgument(is kind: ArgumentKind) -> Self {
    let filtered = matches.filter { match in
      switch kind {
      case .stringLiteral:
        return match.firstArgumentStringValue != nil
      case .emptyString:
        return match.firstArgumentStringValue == ""
      }
    }
    return Self(matches: filtered)
  }

  /// Excludes matches whose first argument string value is in the allowlist.
  public func excluding(_ allowlist: Set<String>) -> Self {
    let filtered = matches.filter { match in
      guard let val = match.firstArgumentStringValue else { return true }
      return !allowlist.contains(val)
    }
    return Self(matches: filtered)
  }

  /// Excludes matches whose first argument string value is in the allowlist collection.
  public func excluding(_ allowlist: [String]) -> Self {
    excluding(Set(allowlist))
  }

  /// Converts matches into invariant violations.
  public func violations(
    code: String,
    message: (CallMatch) -> String,
    fix: String = ""
  ) -> [Violation] {
    matches.map { match in
      Violation(
        code: code,
        file: match.relativePath,
        line: match.line,
        column: match.column,
        message: message(match),
        fix: fix
      )
    }
  }
}

/// Represents a string literal in source.
public struct StringLiteralMatch: Sendable {
  /// String content.
  public let value: String
  /// Containing source file.
  public let file: SourceFile
  /// 1-indexed line.
  public let line: Int
  /// 1-indexed column.
  public let column: Int
}

// MARK: - Internal SwiftSyntax Visitors

private final class FunctionCallVisitor: SyntaxVisitor {
  let targetNames: Set<String>
  let file: SourceFile
  var matches: [CallMatch] = []

  init(targetNames: Set<String>, file: SourceFile) {
    self.targetNames = targetNames
    self.file = file
    super.init(viewMode: .sourceAccurate)
  }

  override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
    let calleeName = node.calledExpression.trimmedDescription
    let memberName: String?
    if let memberAccess = node.calledExpression.as(MemberAccessExprSyntax.self) {
      memberName = memberAccess.declName.baseName.text
    } else if let declRef = node.calledExpression.as(DeclReferenceExprSyntax.self) {
      memberName = declRef.baseName.text
    } else {
      memberName = nil
    }

    let isMatch = targetNames.contains(calleeName) || (memberName.map { targetNames.contains($0) } ?? false)
    if isMatch {
      let loc = node.startLocation(converter: file.converter)
      var stringVal: String?
      var snippet = ""

      if let firstArg = node.arguments.first {
        snippet = firstArg.expression.trimmedDescription
        if let strExpr = firstArg.expression.as(StringLiteralExprSyntax.self) {
          stringVal = strExpr.segments.compactMap { segment -> String? in
            if case .stringSegment(let strSeg) = segment {
              return strSeg.content.text
            }
            return nil
          }.joined()
        }
      }

      matches.append(
        CallMatch(
          callee: calleeName,
          file: file,
          line: loc.line,
          column: loc.column,
          firstArgumentStringValue: stringVal,
          argumentSnippet: snippet
        ))
    }
    return .visitChildren
  }
}

private final class StringLiteralVisitor: SyntaxVisitor {
  let file: SourceFile
  var matches: [StringLiteralMatch] = []

  init(file: SourceFile) {
    self.file = file
    super.init(viewMode: .sourceAccurate)
  }

  override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
    let loc = node.startLocation(converter: file.converter)
    let strVal = node.segments.compactMap { segment -> String? in
      if case .stringSegment(let strSeg) = segment {
        return strSeg.content.text
      }
      return nil
    }.joined()

    matches.append(
      StringLiteralMatch(
        value: strVal,
        file: file,
        line: loc.line,
        column: loc.column
      ))
    return .visitChildren
  }
}
