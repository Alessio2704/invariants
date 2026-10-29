import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { API } from "typescript/unstable/sync";
import type { RuleContext, RuleDefinition, TsAstUnit } from "./index.js";

interface TsUnitConfig {
  readonly tsconfig: string;
}

interface RequestPayload {
  readonly mode: "repo" | "fixture";
  readonly repoRoot: string;
  readonly ruleDir: string;
  readonly files: readonly string[];
  readonly unitFiles?: Readonly<Record<string, readonly string[]>>;
  readonly ast?: {
    readonly ts?: Readonly<Record<string, TsUnitConfig>>;
    readonly swift?: Readonly<Record<string, { readonly indexStore: string }>>;
  };
  readonly languages?: {
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
    const resolvedProjects: Array<{
      unitName: string;
      configPath: string;
      relConfig?: string;
      files: readonly string[];
    }> = [];

    // Determine unit files mapping
    let unitFiles: Record<string, readonly string[]> = {};
    if (request.unitFiles && Object.keys(request.unitFiles).length > 0) {
      unitFiles = { ...request.unitFiles };
    } else if (request.ast?.ts && Object.keys(request.ast.ts).length > 0) {
      for (const unitName of Object.keys(request.ast.ts)) {
        unitFiles[unitName] = request.files;
      }
    } else {
      unitFiles = { main: request.files };
    }

    if (request.mode === "repo") {
      const tsAst = request.ast?.ts;
      if (!tsAst || Object.keys(tsAst).length === 0) {
        // Fallback to legacy request.languages.ts if present
        const legacyTs = request.languages?.ts;
        if (!legacyTs || !Array.isArray(legacyTs.tsconfig) || legacyTs.tsconfig.length === 0) {
          process.stderr.write(
            "INDEX STALE: TypeScript analysis requires at least one configured tsconfig in registry.lock\n",
          );
          process.exit(2);
        }
        for (const [idx, relConfig] of legacyTs.tsconfig.entries()) {
          const candidate = path.resolve(request.repoRoot, relConfig);
          if (!fs.existsSync(candidate)) {
            process.stderr.write(`INDEX STALE: Configured tsconfig does not exist: ${candidate}\n`);
            process.exit(2);
          }
          resolvedProjects.push({
            unitName: idx === 0 ? "main" : `unit_${idx}`,
            configPath: candidate,
            relConfig,
            files: request.files,
          });
        }
      } else {
        for (const [unitName, files] of Object.entries(unitFiles)) {
          const unitConfig = tsAst[unitName];
          if (
            !unitConfig ||
            typeof unitConfig.tsconfig !== "string" ||
            unitConfig.tsconfig.trim().length === 0
          ) {
            process.stderr.write(
              `INDEX STALE: Missing or invalid tsconfig for unit '${unitName}' in registry.ast.ts\n`,
            );
            process.exit(2);
          }
          const candidate = path.resolve(request.repoRoot, unitConfig.tsconfig);
          if (!fs.existsSync(candidate)) {
            process.stderr.write(`INDEX STALE: Configured tsconfig does not exist: ${candidate}\n`);
            process.exit(2);
          }
          resolvedProjects.push({
            unitName,
            configPath: candidate,
            relConfig: unitConfig.tsconfig,
            files,
          });
        }
      }
    } else if (request.mode === "fixture") {
      // Synthesize minimal tsconfig per active unit scoped to that unit's fixture files
      tempConfigDir = fs.mkdtempSync(path.join(os.tmpdir(), "inv_ts_"));
      for (const [unitName, files] of Object.entries(unitFiles)) {
        if (files.length === 0) continue;
        const syntheticConfigPath = path.join(tempConfigDir, `tsconfig_${unitName}.json`);
        const syntheticConfig = {
          compilerOptions: {
            target: "ES2022",
            module: "NodeNext",
            moduleResolution: "NodeNext",
          },
          files: files.map((f) => (path.isAbsolute(f) ? f : path.resolve(request.repoRoot, f))),
        };
        fs.writeFileSync(syntheticConfigPath, JSON.stringify(syntheticConfig, null, 2));
        resolvedProjects.push({
          unitName,
          configPath: syntheticConfigPath,
          files,
        });
      }
    } else {
      throw new Error(`Invalid request mode: ${String((request as { mode?: unknown }).mode)}`);
    }

    const openProjects = resolvedProjects.map((p) => p.configPath);
    const snapshot = api.updateSnapshot({ openProjects });
    const allProjects = snapshot.getProjects();

    const astUnits: Record<string, TsAstUnit> = {};
    for (const [i, projInfo] of resolvedProjects.entries()) {
      // Match project by configFileName or index
      const project =
        allProjects.find(
          (p) => path.resolve(p.configFileName) === path.resolve(projInfo.configPath),
        ) ?? allProjects[i];

      astUnits[projInfo.unitName] = {
        name: projInfo.unitName,
        files: projInfo.files,
        tsconfig: projInfo.relConfig,
        sourceFile(filePath: string) {
          const full = path.isAbsolute(filePath)
            ? filePath
            : path.resolve(request.repoRoot, filePath);
          let sf = project?.program?.getSourceFile(full);
          if (sf) return sf;
          if (fs.existsSync(full)) {
            try {
              const real = fs.realpathSync(full);
              sf = project?.program?.getSourceFile(real);
              if (sf) return sf;
            } catch {}
          }
          return undefined;
        },
        checker: project?.checker,
      };
    }

    for (const [unitName, files] of Object.entries(unitFiles)) {
      if (!astUnits[unitName]) {
        astUnits[unitName] = {
          name: unitName,
          files: files ?? [],
          sourceFile: () => undefined,
          checker: undefined,
        };
      }
    }

    const primaryProject = allProjects[0];

    const ctx: RuleContext = {
      mode: request.mode,
      repoRoot: request.repoRoot,
      ruleDir: request.ruleDir,
      files: request.files,
      ast: astUnits,
      sourceFile(filePath: string) {
        const full = path.isAbsolute(filePath)
          ? filePath
          : path.resolve(request.repoRoot, filePath);
        for (const proj of allProjects) {
          let sf = proj.program?.getSourceFile(full);
          if (sf) return sf;
          if (fs.existsSync(full)) {
            try {
              const real = fs.realpathSync(full);
              sf = proj.program?.getSourceFile(real);
              if (sf) return sf;
            } catch {}
          }
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
