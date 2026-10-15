import InvariantKit

@main
struct Rule: SwiftRule {
    func check(_ ctx: RuleContext) throws(RuleError) -> [Violation] {
        // Compose AST filters over ctx.swift.files:
        return []
    }
}
