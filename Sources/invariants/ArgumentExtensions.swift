public import ArgumentParser
public import Core
import Foundation

extension SupportedLanguage: ExpressibleByArgument {
  public init?(argument: String) {
    if argument.contains(",") {
      return nil
    }
    self.init(rawValue: argument)
  }
}
