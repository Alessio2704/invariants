import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { API } from "typescript/unstable/sync";
import type { RuleContext, RuleDefinition } from "./index.js";

interface RequestPayload {
  readonly mode: "repo" | "fixture";
  readonly repoRoot: string;
  readonly ruleDir: string;
  readonly files: readonly string[];
  readonly languages: {
    readonly ts?: {
      readonly tsconfig?: readonly string[];
    };
  };
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  if (args.length < 2) {
    process.stderr.write("Usage: runner <rule.ts> <request.json>\n");
    process.exit(1);
  }

  const ruleArg = args[0];
  const requestArg = args[1];
  if (!ruleArg || !requestArg) {
    process.stderr.write("Usage: runner <rule.ts> <request.json>\n");
    process.exit(1);
  }

  const rulePath = path.resolve(ruleArg);
  const requestPath = path.resolve(requestArg);

  const requestContent = fs.readFileSync(requestPath, "utf8");
  const request = JSON.parse(requestContent) as RequestPayload;

  const api = new API();
  let tempConfigDir: string | undefined;

  try {
    const resolvedConfigPaths: string[] = [];

    if (request.mode === "repo") {
      const tsConfig = request.languages.ts;
      if (!tsConfig || !Array.isArray(tsConfig.tsconfig) || tsConfig.tsconfig.length === 0) {
        process.stderr.write(
          "INDEX STALE: TypeScript analysis requires at least one configured tsconfig in registry.lock\n",
        );
        process.exit(2);
      }

      for (const relConfig of tsConfig.tsconfig) {
        if (typeof relConfig !== "string" || relConfig.trim().length === 0) {
          process.stderr.write("INDEX STALE: Invalid tsconfig path in configuration\n");
          process.exit(2);
        }
        const candidate = path.resolve(request.repoRoot, relConfig);
        if (!fs.existsSync(candidate)) {
          process.stderr.write(`INDEX STALE: Configured tsconfig does not exist: ${candidate}\n`);
          process.exit(2);
        }
        resolvedConfigPaths.push(candidate);
      }
    } else if (request.mode === "fixture") {
      // Synthesize minimal tsconfig scoped strictly to the fixture files under test
      tempConfigDir = fs.mkdtempSync(path.join(os.tmpdir(), "inv_ts_"));
      const syntheticConfigPath = path.join(tempConfigDir, "tsconfig.json");
      const syntheticConfig = {
        compilerOptions: {
          target: "ES2022",
          module: "NodeNext",
          moduleResolution: "NodeNext",
        },
        files: request.files.map((f) => path.resolve(request.repoRoot, f)),
      };
      fs.writeFileSync(syntheticConfigPath, JSON.stringify(syntheticConfig, null, 2));
      resolvedConfigPaths.push(syntheticConfigPath);
    } else {
      throw new Error(`Invalid request mode: ${String((request as { mode?: unknown }).mode)}`);
    }

    const snapshot = api.updateSnapshot({ openProjects: resolvedConfigPaths });
    const projects = snapshot.getProjects();
    const primaryProject = projects[0];

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
        for (const proj of projects) {
          const sf = proj.program?.getSourceFile(full);
          if (sf) return sf;
        }
        return undefined;
      },
      checker: primaryProject?.checker,
    };

    // Register bundled TS loader so that rule.ts can be loaded directly and resolve @invariants/kit
    const loaderName = fs.existsSync(new URL("./loader.ts", import.meta.url))
      ? "./loader.ts"
      : "./loader.js";
    const loaderURL = new URL(loaderName, import.meta.url);
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

    const result = await Promise.resolve(rule.check(ctx));
    if (!Array.isArray(result)) {
      throw new Error(
        `Rule contract violation at ${rulePath}: check() must return an Array of Violation objects. Received: ${typeof result}`,
      );
    }

    for (let i = 0; i < result.length; i++) {
      const v = result[i];
      if (
        typeof v !== "object" ||
        v === null ||
        typeof v.code !== "string" ||
        typeof v.file !== "string" ||
        typeof v.line !== "number" ||
        typeof v.column !== "number" ||
        typeof v.message !== "string" ||
        typeof v.fix !== "string"
      ) {
        throw new Error(
          `Violation contract violation at ${rulePath} (index ${i}): every violation must be an object with string 'code', 'file', 'message', 'fix' and number 'line', 'column'. Received: ${JSON.stringify(v)}`,
        );
      }
    }

    process.stdout.write(`${JSON.stringify(result)}\n`);
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
