public import ArgumentParser
import Foundation
import InvariantCore

extension SupportedLanguage: ExpressibleByArgument {}

/// Terminal and interactive command-line interface utilities.
enum CLIUtil {
  /// Whether current process has an interactive standard input terminal attached.
  static var isInteractive: Bool {
    isatty(FileHandle.standardInput.fileDescriptor) != 0
  }
}
