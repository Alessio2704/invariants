import Foundation

/// Declarative specification for interactive terminal configuration prompts and candidate presentation.
public struct LanguageConfigPromptDescriptor: Sendable, Equatable {
  /// Defines how discovered candidates are presented to the user during interactive configuration.
  public enum SelectionStyle: Sendable, Equatable {
    /// Select one candidate from discovered options with an optional custom fallback.
    case single(selectionTitle: String)
    /// Confirm all discovered candidates together, or prompt for a manual custom fallback.
    case multiple(confirmationQuestion: String)
  }

  /// Message printed when no candidates are detected in the repository.
  public var noCandidatesMessage: String
  /// Prompt text when asking the user to manually enter a path when no candidates are found.
  public var manualPromptQuestion: String
  /// Prompt text when asking for a custom path after rejecting discovered candidates.
  public var manualFallbackQuestion: String
  /// How discovered candidates should be presented to the user.
  public var selectionStyle: SelectionStyle

  public init(
    noCandidatesMessage: String,
    manualPromptQuestion: String,
    manualFallbackQuestion: String? = nil,
    selectionStyle: SelectionStyle
  ) {
    self.noCandidatesMessage = noCandidatesMessage
    self.manualPromptQuestion = manualPromptQuestion
    self.manualFallbackQuestion = manualFallbackQuestion ?? manualPromptQuestion
    self.selectionStyle = selectionStyle
  }
}
