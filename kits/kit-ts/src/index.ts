import * as ast from "typescript/unstable/ast";

export { ast };

/**
 * An architectural violation diagnosed by an invariant rule.
 */
export interface Violation {
  readonly code: string;
  readonly file: string;
  readonly line: number;
  readonly column: number;
  readonly message: string;
  readonly fix: string;
}

/**
 * A compilation/AST unit for TypeScript analysis.
 */
export interface TsAstUnit {
  readonly name: string;
  readonly files: readonly string[];
  readonly tsconfig?: string | undefined;
  sourceFile(filePath: string): unknown;
  readonly checker: unknown | undefined;
}

/**
 * Execution context passed to rule.check().
 */
export interface RuleContext {
  readonly mode: "repo" | "fixture";
  readonly repoRoot: string;
  readonly ruleDir: string;
  readonly files: readonly string[];
  readonly ast: Readonly<Record<string, TsAstUnit>>;

  /**
   * Returns the TypeScript AST SourceFile for the given path.
   */
  sourceFile(filePath: string): unknown;

  /**
   * The TypeScript TypeChecker, if project type information is loaded.
   */
  readonly checker: unknown | undefined;
}

/**
 * Invariant rule definition.
 */
export interface RuleDefinition {
  check(ctx: RuleContext): Promise<readonly Violation[]> | readonly Violation[];
}

/**
 * Helper function for authoring type-safe invariant rules.
 */
export function defineRule(definition: RuleDefinition): RuleDefinition {
  return definition;
}
