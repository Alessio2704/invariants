import * as fs from "node:fs";
import { fileURLToPath } from "node:url";
import ts from "typescript";

interface ResolveContext {
  conditions: string[];
  parentURL?: string | undefined;
}

interface ResolveResult {
  url: string;
  format?: string | null | undefined;
  shortCircuit?: boolean | undefined;
}

interface LoadContext {
  conditions: string[];
  format?: string | null | undefined;
}

interface LoadResult {
  format: string;
  source: string | ArrayBuffer | SharedArrayBuffer | Uint8Array;
  shortCircuit?: boolean | undefined;
}

type NextResolve = (specifier: string, context: ResolveContext) => Promise<ResolveResult>;
type NextLoad = (url: string, context: LoadContext) => Promise<LoadResult>;

export async function resolve(
  specifier: string,
  context: ResolveContext,
  nextResolve: NextResolve,
): Promise<ResolveResult> {
  if (specifier === "@invariants/kit") {
    const indexName = fs.existsSync(new URL("./index.ts", import.meta.url))
      ? "./index.ts"
      : "./index.js";
    const indexPath = new URL(indexName, import.meta.url).href;
    return {
      url: indexPath,
      format: "module",
      shortCircuit: true,
    };
  }

  return nextResolve(specifier, context);
}

interface TranspileOptions {
  compilerOptions: {
    module?: number | undefined;
    target?: number | undefined;
  };
  fileName?: string | undefined;
}

interface TranspileResult {
  outputText: string;
}

interface TSCompiler {
  transpileModule(source: string, options: TranspileOptions): TranspileResult;
  ModuleKind?: { ESNext: number } | undefined;
  ScriptTarget?: { ES2022: number } | undefined;
}

export async function load(
  url: string,
  context: LoadContext,
  nextLoad: NextLoad,
): Promise<LoadResult> {
  if (url.endsWith(".ts")) {
    const filePath = fileURLToPath(url);
    const sourceText = fs.readFileSync(filePath, "utf8");
    const rawTs =
      (ts as unknown as { default?: TSCompiler }).default ?? (ts as unknown as TSCompiler);
    const moduleKind = rawTs.ModuleKind?.ESNext ?? 99;
    const scriptTarget = rawTs.ScriptTarget?.ES2022 ?? 9;
    const transpiled = rawTs.transpileModule(sourceText, {
      compilerOptions: {
        module: moduleKind,
        target: scriptTarget,
      },
      fileName: filePath,
    });
    return {
      format: "module",
      source: transpiled.outputText,
      shortCircuit: true,
    };
  }

  return nextLoad(url, context);
}
