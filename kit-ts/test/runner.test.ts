import { execFileSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

describe("TS Rule Runner process contract", () => {
  let tmpDir: string;
  const runnerPath = path.resolve(__dirname, "../dist/runner.js");

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "runner_test_"));
  });

  afterEach(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  it("executes rule and outputs violations as JSON array to stdout", () => {
    const testFile = path.join(tmpDir, "sample.ts");
    fs.writeFileSync(testFile, 'export const greeting = "hello";\n');

    const ruleFile = path.join(tmpDir, "rule.js");
    fs.writeFileSync(
      ruleFile,
      `export default {
  check(ctx) {
    const sf = ctx.sourceFile("sample.ts");
    return [
      {
        code: "NO-HELLO",
        file: "sample.ts",
        line: 1,
        column: 25,
        message: "Raw hello string found",
        fix: "Use localized string"
      }
    ];
  }
};
`,
    );

    const requestFile = path.join(tmpDir, "request.json");
    fs.writeFileSync(
      requestFile,
      JSON.stringify({
        mode: "fixture",
        repoRoot: tmpDir,
        ruleDir: tmpDir,
        files: ["sample.ts"],
      }),
    );

    const stdout = execFileSync(process.execPath, [runnerPath, ruleFile, requestFile], {
      encoding: "utf8",
    });

    const violations = JSON.parse(stdout);
    expect(violations).toHaveLength(1);
    expect(violations[0].code).toBe("NO-HELLO");
    expect(violations[0].file).toBe("sample.ts");
  });

  it("executes TypeScript rule (.ts) importing @invariants/kit via bundled loader", () => {
    const testFile = path.join(tmpDir, "target.ts");
    fs.writeFileSync(testFile, 'export const val = "secret";\n');

    const ruleFile = path.join(tmpDir, "rule.ts");
    fs.writeFileSync(
      ruleFile,
      `import { defineRule } from "@invariants/kit";

interface ConfigItem {
  key: string;
}

export default defineRule({
  check(ctx) {
    const item: ConfigItem = { key: "secret" };
    return [
      {
        code: "NO-SECRET",
        file: "target.ts",
        line: 1,
        column: 1,
        message: \`Secret found: \${item.key}\`,
        fix: "Remove secret",
      },
    ];
  },
});
`,
    );

    const requestFile = path.join(tmpDir, "request.json");
    fs.writeFileSync(
      requestFile,
      JSON.stringify({
        mode: "fixture",
        repoRoot: tmpDir,
        ruleDir: tmpDir,
        files: ["target.ts"],
      }),
    );

    const stdout = execFileSync(process.execPath, [runnerPath, ruleFile, requestFile], {
      encoding: "utf8",
    });

    const violations = JSON.parse(stdout);
    expect(violations).toHaveLength(1);
    expect(violations[0].code).toBe("NO-SECRET");
    expect(violations[0].message).toBe("Secret found: secret");
  });
});
