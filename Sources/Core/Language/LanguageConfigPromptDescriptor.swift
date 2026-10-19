import Foundation

/// Declarative specification for interactive terminal configuration prompts and candidate presentation.
public struct LanguageConfigPromptDescriptor: Sendable, Equatable {
  /// Defines how discovered analysis inputs are presented to the user during interactive configuration.
  public enum SelectionStyle: Sendable, Equatable {
    /// Select one candidate from discovered options with an optional custom fallback.
    case single(selectionTitle: String)
    /// Confirm all discovered candidates together, or prompt for a manual custom fallback.
    case multiple(confirmationQuestion: String)
  }

  /// Message printed when no analysis inputs are detected in the repository.
  public var noInputsFoundMessage: String
  /// Prompt text when asking the user to manually enter a path when no inputs are found.
  public var manualPromptQuestion: String
  /// Prompt text when asking for a custom path after rejecting discovered inputs.
  public var manualFallbackQuestion: String
  /// How discovered analysis inputs should be presented to the user.
  public var selectionStyle: SelectionStyle

  public init(
    noInputsFoundMessage: String,
    manualPromptQuestion: String,
    manualFallbackQuestion: String? = nil,
    selectionStyle: SelectionStyle
  ) {
    self.noInputsFoundMessage = noInputsFoundMessage
    self.manualPromptQuestion = manualPromptQuestion
    self.manualFallbackQuestion = manualFallbackQuestion ?? manualPromptQuestion
    self.selectionStyle = selectionStyle
  }
}
