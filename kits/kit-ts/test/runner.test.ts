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

  it("isolates ctx.ast['web'] and ctx.ast['bff'] with independent TypeCheckers", () => {
    const webDir = path.join(tmpDir, "web");
    const bffDir = path.join(tmpDir, "bff");
    fs.mkdirSync(webDir, { recursive: true });
    fs.mkdirSync(bffDir, { recursive: true });

    const webFile = path.join(webDir, "app.ts");
    const bffFile = path.join(bffDir, "service.ts");
    fs.writeFileSync(webFile, "export interface WebApp { id: string; }\n");
    fs.writeFileSync(bffFile, "export interface BffService { port: number; }\n");

    const webTsconfig = path.join(webDir, "tsconfig.json");
    const bffTsconfig = path.join(bffDir, "tsconfig.json");
    fs.writeFileSync(
      webTsconfig,
      JSON.stringify({
        compilerOptions: { target: "ES2022", module: "NodeNext" },
        files: [webFile],
      }),
    );
    fs.writeFileSync(
      bffTsconfig,
      JSON.stringify({
        compilerOptions: { target: "ES2022", module: "NodeNext" },
        files: [bffFile],
      }),
    );

    const ruleFile = path.join(tmpDir, "multi_unit_checker_rule.js");
    fs.writeFileSync(
      ruleFile,
      `export default {
  check(ctx) {
    const violations = [];
    const webUnit = ctx.ast["web"];
    const bffUnit = ctx.ast["bff"];

    if (!webUnit || !bffUnit) {
      violations.push({ code: "ERR-UNITS", file: "app.ts", line: 1, column: 1, message: "Missing unit", fix: "" });
      return violations;
    }

    const webSf = webUnit.sourceFile("web/app.ts");
    const bffSf = bffUnit.sourceFile("bff/service.ts");
    if (!webSf) violations.push({ code: "ERR-WEB-SF", file: "web/app.ts", line: 1, column: 1, message: "No web sf", fix: "" });
    if (!bffSf) violations.push({ code: "ERR-BFF-SF", file: "bff/service.ts", line: 1, column: 1, message: "No bff sf", fix: "" });

    // Verify distinct type checkers per project
    if (!webUnit.checker) violations.push({ code: "ERR-WEB-CHECKER", file: "web/app.ts", line: 1, column: 1, message: "No web checker", fix: "" });
    if (!bffUnit.checker) violations.push({ code: "ERR-BFF-CHECKER", file: "bff/service.ts", line: 1, column: 1, message: "No bff checker", fix: "" });
    if (webUnit.checker === bffUnit.checker) {
      violations.push({ code: "ERR-SAME-CHECKER", file: "web/app.ts", line: 1, column: 1, message: "Checkers must be isolated", fix: "" });
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
        files: ["web/app.ts", "bff/service.ts"],
        unitFiles: {
          web: ["web/app.ts"],
          bff: ["bff/service.ts"],
        },
        ast: {
          ts: {
            web: { tsconfig: "web/tsconfig.json" },
            bff: { tsconfig: "bff/tsconfig.json" },
          },
        },
      }),
    );

    const stdout = execFileSync(process.execPath, [runnerPath, ruleFile, requestFile], {
      encoding: "utf8",
    });

    const violations = JSON.parse(stdout);
    expect(violations).toHaveLength(0);
  });

  it("synthesizes separate tsconfig projects in fixture mode for multi-unit rules", () => {
    const webFile = path.join(tmpDir, "web_sample.ts");
    const bffFile = path.join(tmpDir, "bff_sample.ts");
    fs.writeFileSync(webFile, "export const a = 1;\n");
    fs.writeFileSync(bffFile, "export const b = 2;\n");

    const ruleFile = path.join(tmpDir, "fixture_rule.js");
    fs.writeFileSync(
      ruleFile,
      `export default {
  check(ctx) {
    const violations = [];
    if (!ctx.ast["web"] || !ctx.ast["bff"]) {
      violations.push({ code: "MISSING-AST-UNITS", file: "test.ts", line: 1, column: 1, message: "Missing units", fix: "" });
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
        mode: "fixture",
        repoRoot: tmpDir,
        ruleDir: tmpDir,
        files: ["web_sample.ts", "bff_sample.ts"],
        unitFiles: {
          web: ["web_sample.ts"],
          bff: ["bff_sample.ts"],
        },
        ast: {
          ts: {
            web: { tsconfig: "web/tsconfig.json" },
            bff: { tsconfig: "bff/tsconfig.json" },
          },
        },
      }),
    );

    const stdout = execFileSync(process.execPath, [runnerPath, ruleFile, requestFile], {
      encoding: "utf8",
    });

    const violations = JSON.parse(stdout);
    expect(violations).toHaveLength(0);
  });

  it("exits with status 2 and INDEX STALE when any scoped unit tsconfig is missing in repo mode", () => {
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
        unitFiles: {
          web: ["app.ts"],
        },
        ast: {
          ts: {
            web: { tsconfig: "nonexistent/web/tsconfig.json" },
          },
        },
      }),
    );

    try {
      execFileSync(process.execPath, [runnerPath, ruleFile, requestFile], {
        encoding: "utf8",
        stdio: "pipe",
      });
      expect.unreachable(
        "Runner should have exited with code 2 for missing unit tsconfig in repo mode",
      );
    } catch (err: unknown) {
      const error = err as { status: number; stderr: string };
      expect(error.status).toBe(2);
      expect(error.stderr).toContain("INDEX STALE: Configured tsconfig does not exist");
    }
  });
});
