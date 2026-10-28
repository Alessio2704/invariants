import Foundation

@testable import Terminal

extension Terminal {
  static func withInteractiveSession<T: Sendable>(
    mode: InteractiveMode = .forceInteractive,
    readLineHandler: (@Sendable () -> String?)? = { "y" },
    operation: () async throws -> T
  ) async rethrows -> T {
    try await $taskLocalInteractiveMode.withValue(mode) {
      try await $taskLocalReadLine.withValue(readLineHandler) {
        try await operation()
      }
    }
  }
}
