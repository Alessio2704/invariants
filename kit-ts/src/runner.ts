import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { API } from "typescript/unstable/sync";
import type { RuleContext, RuleDefinition, Violation } from "./index.js";

interface RequestPayload {
  readonly mode: "repo" | "fixture";
  readonly repoRoot: string;
  readonly ruleDir: string;
  readonly files: readonly string[];
  readonly languages: {
    readonly ts?:
      | {
          readonly tsconfig?: readonly string[] | undefined;
        }
      | undefined;
  };
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  if (args.length < 2) {
    process.stderr.write("Usage: runner <rule.ts> <request.json>\n");
    process.exit(1);
  }

  const rulePath = path.resolve(args[0] ?? "");
  const requestPath = path.resolve(args[1] ?? "");

  const requestContent = fs.readFileSync(requestPath, "utf8");
  const request = JSON.parse(requestContent) as RequestPayload;

  const api = new API();
  let tempConfigDir: string | undefined;

  try {
    let resolvedConfigPath = "";
    if (request.languages.ts?.tsconfig && request.languages.ts.tsconfig.length > 0) {
      const firstConfig = request.languages.ts.tsconfig[0];
      if (firstConfig) {
        const candidate = path.resolve(request.repoRoot, firstConfig);
        if (fs.existsSync(candidate)) {
          resolvedConfigPath = candidate;
        }
      }
    }

    if (!resolvedConfigPath) {
      // Synthesize minimal tsconfig for fixture or loose files
      tempConfigDir = fs.mkdtempSync(path.join(os.tmpdir(), "inv_ts_"));
      resolvedConfigPath = path.join(tempConfigDir, "tsconfig.json");
      const syntheticConfig = {
        compilerOptions: {
          target: "ES2022",
          module: "NodeNext",
          moduleResolution: "NodeNext",
        },
        files: request.files.map((f) => path.resolve(request.repoRoot, f)),
      };
      fs.writeFileSync(resolvedConfigPath, JSON.stringify(syntheticConfig, null, 2));
    }

    const snapshot = api.updateSnapshot({ openProjects: [resolvedConfigPath] });
    const project = snapshot.getProjects()[0];
    const program = project?.program;
    const checker = project?.checker;

    const ctx: RuleContext = {
      mode: request.mode,
      repoRoot: request.repoRoot,
      ruleDir: request.ruleDir,
      files: request.files,
      languages: request.languages,
      sourceFile(filePath: string) {
        const full = path.isAbsolute(filePath)
          ? filePath
          : path.resolve(request.repoRoot, filePath);
        return program?.getSourceFile(full);
      },
      checker,
    };

    // Register bundled TS loader so that rule.ts can be loaded directly and resolve @invariants/kit
    const loaderURL = new URL("./loader.js", import.meta.url);
    const { register } = await import("node:module");
    const { pathToFileURL } = await import("node:url");
    register(loaderURL, import.meta.url);

    // Load rule module
    const ruleURL = pathToFileURL(rulePath).href;
    const ruleModule = (await import(ruleURL)) as { default?: RuleDefinition } & RuleDefinition;
    const rule = ruleModule.default ?? ruleModule;

    if (typeof rule?.check !== "function") {
      throw new Error(`Rule at ${rulePath} does not export a check() function`);
    }

    const violations = await Promise.resolve(rule.check(ctx));
    const output: readonly Violation[] = violations ?? [];

    process.stdout.write(`${JSON.stringify(output)}\n`);
  } catch (err) {
    const message = err instanceof Error ? (err.stack ?? err.message) : String(err);
    process.stderr.write(`TS Rule execution error: ${message}\n`);
    process.exit(1);
  } finally {
    api.close();
    if (tempConfigDir) {
      try {
        fs.rmSync(tempConfigDir, { recursive: true, force: true });
      } catch {
        // Ignore cleanup error
      }
    }
  }
}

main().catch((err) => {
  process.stderr.write(`Fatal TS runner error: ${String(err)}\n`);
  process.exit(1);
});
