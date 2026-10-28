import { execFileSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

describe("TS Rule Runner process contract", () => {
  let tmpDir: string;
  const runnerPath = fs.existsSync(path.resolve(__dirname, "../src/runner.ts"))
    ? path.resolve(__dirname, "../src/runner.ts")
    : path.resolve(__dirname, "../dist/runner.js");

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
        languages: { ts: { tsconfig: ["tsconfig.json"] } },
      }),
    );

    const stdout = execFileSync(process.execPath, [runnerPath, ruleFile, requestFile], {
      encoding: "utf8",
    });

    const violations = JSON.parse(stdout);
    expect(violations).toHaveLength(1);
    expect(violations[0].code).toBe("NO-HELLO");
    expect(violations[0].file).toBe("sample.ts");
    expect(violations[0].fix).toBe("Use localized string");
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
        languages: { ts: { tsconfig: ["tsconfig.json"] } },
      }),
    );

    const stdout = execFileSync(process.execPath, [runnerPath, ruleFile, requestFile], {
      encoding: "utf8",
    });

    const violations = JSON.parse(stdout);
    expect(violations).toHaveLength(1);
    expect(violations[0].code).toBe("NO-SECRET");
    expect(violations[0].message).toBe("Secret found: secret");
    expect(violations[0].fix).toBe("Remove secret");
  });

  it("strictly rejects rule check() returning non-array without silent fallbacks", () => {
    const ruleFile = path.join(tmpDir, "rule_undefined.js");
    fs.writeFileSync(
      ruleFile,
      `export default {
  check(ctx) {
    // Forgot to return an array!
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
        files: [],
        languages: {},
      }),
    );

    try {
      execFileSync(process.execPath, [runnerPath, ruleFile, requestFile], {
        encoding: "utf8",
        stdio: "pipe",
      });
      expect.unreachable("Runner should have failed on non-array check() result");
    } catch (err: unknown) {
      const error = err as { status: number; stderr: string };
      expect(error.status).toBe(1);
      expect(error.stderr).toContain("check() must return an Array of Violation objects");
    }
  });

  it("strictly rejects violation object missing required fix field", () => {
    const ruleFile = path.join(tmpDir, "rule_missing_fix.js");
    fs.writeFileSync(
      ruleFile,
      `export default {
  check(ctx) {
    return [
      {
        code: "NO-FIX",
        file: "sample.ts",
        line: 1,
        column: 1,
        message: "Missing fix field"
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
        languages: {},
      }),
    );

    try {
      execFileSync(process.execPath, [runnerPath, ruleFile, requestFile], {
        encoding: "utf8",
        stdio: "pipe",
      });
      expect.unreachable("Runner should have failed on violation missing fix");
    } catch (err: unknown) {
      const error = err as { status: number; stderr: string };
      expect(error.status).toBe(1);
      expect(error.stderr).toContain("Violation contract violation");
    }
  });

  it("opens multiple configured tsconfig projects and resolves source files across projects", () => {
    const projADir = path.join(tmpDir, "apps/web");
    const projBDir = path.join(tmpDir, "packages/ui");
    fs.mkdirSync(projADir, { recursive: true });
    fs.mkdirSync(projBDir, { recursive: true });

    const fileA = path.join(projADir, "app.ts");
    const fileB = path.join(projBDir, "button.ts");
    fs.writeFileSync(fileA, "export const app = 1;\n");
    fs.writeFileSync(fileB, "export const button = 2;\n");

    const tsconfigA = path.join(projADir, "tsconfig.json");
    const tsconfigB = path.join(projBDir, "tsconfig.json");
    fs.writeFileSync(
      tsconfigA,
      JSON.stringify({
        compilerOptions: { target: "ES2022", module: "NodeNext" },
        files: [fileA],
      }),
    );
    fs.writeFileSync(
      tsconfigB,
      JSON.stringify({
        compilerOptions: { target: "ES2022", module: "NodeNext" },
        files: [fileB],
      }),
    );

    const ruleFile = path.join(tmpDir, "multi_rule.js");
    fs.writeFileSync(
      ruleFile,
      `export default {
  check(ctx) {
    const sfA = ctx.sourceFile("apps/web/app.ts");
    const sfB = ctx.sourceFile("packages/ui/button.ts");
    const violations = [];
    if (!sfA) {
      violations.push({ code: "MISSING-A", file: "apps/web/app.ts", line: 1, column: 1, message: "A missing", fix: "Fix A" });
    }
    if (!sfB) {
      violations.push({ code: "MISSING-B", file: "packages/ui/button.ts", line: 1, column: 1, message: "B missing", fix: "Fix B" });
    }
    return violations;
  }
};
`,
    );

    const requestFile = path.join(tmpDir, "request.json");
    fs.writeFileSync(
      requestFile,
      JSON.stringify({
        mode: "repo",
        repoRoot: tmpDir,
        ruleDir: tmpDir,
        files: ["apps/web/app.ts", "packages/ui/button.ts"],
        languages: {
          ts: {
            tsconfig: ["apps/web/tsconfig.json", "packages/ui/tsconfig.json"],
          },
        },
      }),
    );

    const stdout = execFileSync(process.execPath, [runnerPath, ruleFile, requestFile], {
      encoding: "utf8",
    });

    const violations = JSON.parse(stdout);
    // Both source files were found across the two openProjects, so zero violations
    expect(violations).toHaveLength(0);
  });

  it("exits with status 2 and INDEX STALE when configured tsconfig is missing in repo mode", () => {
    const ruleFile = path.join(tmpDir, "rule.js");
    fs.writeFileSync(ruleFile, "export default { check() { return []; } };\n");

    const requestFile = path.join(tmpDir, "request.json");
    fs.writeFileSync(
      requestFile,
      JSON.stringify({
        mode: "repo",
        repoRoot: tmpDir,
        ruleDir: tmpDir,
        files: ["app.ts"],
        languages: {
          ts: {
            tsconfig: ["nonexistent/tsconfig.json"],
          },
        },
      }),
    );

    try {
      execFileSync(process.execPath, [runnerPath, ruleFile, requestFile], {
        encoding: "utf8",
        stdio: "pipe",
      });
      expect.unreachable("Runner should have exited with code 2 for missing tsconfig in repo mode");
    } catch (err: unknown) {
      const error = err as { status: number; stderr: string };
      expect(error.status).toBe(2);
      expect(error.stderr).toContain("INDEX STALE: Configured tsconfig does not exist");
    }
  });

  it("exits with status 2 and INDEX STALE when tsconfig is unconfigured in repo mode", () => {
    const ruleFile = path.join(tmpDir, "rule.js");
    fs.writeFileSync(ruleFile, "export default { check() { return []; } };\n");

    const requestFile = path.join(tmpDir, "request.json");
    fs.writeFileSync(
      requestFile,
      JSON.stringify({
        mode: "repo",
        repoRoot: tmpDir,
        ruleDir: tmpDir,
        files: ["app.ts"],
        languages: {},
      }),
    );

    try {
      execFileSync(process.execPath, [runnerPath, ruleFile, requestFile], {
        encoding: "utf8",
        stdio: "pipe",
      });
      expect.unreachable(
        "Runner should have exited with code 2 for unconfigured tsconfig in repo mode",
      );
    } catch (err: unknown) {
      const error = err as { status: number; stderr: string };
      expect(error.status).toBe(2);
      expect(error.stderr).toContain(
        "INDEX STALE: TypeScript analysis requires at least one configured tsconfig",
      );
    }
  });
});
