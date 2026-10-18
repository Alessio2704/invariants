import { describe, expect, it } from "vitest";
import { ast, defineRule } from "../src/index.js";

describe("@invariants/kit API", () => {
  it("defines rules cleanly", () => {
    const rule = defineRule({
      check(ctx) {
        return [
          {
            code: "TEST-01",
            file: "test.ts",
            line: 1,
            column: 1,
            message: "Test violation",
          },
        ];
      },
    });

    expect(typeof rule.check).toBe("function");
  });

  it("exports TS 7 AST helpers", () => {
    expect(typeof ast.isStringLiteral).toBe("function");
    expect(typeof ast.isIdentifier).toBe("function");
    expect(typeof ast.isCallExpression).toBe("function");
  });
});
