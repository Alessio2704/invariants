import * as fs from "node:fs";
import { stripTypeScriptTypes } from "node:module";
import { fileURLToPath } from "node:url";

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

export async function load(
  url: string,
  context: LoadContext,
  nextLoad: NextLoad,
): Promise<LoadResult> {
  if (url.endsWith(".ts")) {
    const filePath = fileURLToPath(url);
    const sourceText = fs.readFileSync(filePath, "utf8");
    const transpiledSource = stripTypeScriptTypes(sourceText);
    return {
      format: "module",
      source: transpiledSource,
      shortCircuit: true,
    };
  }

  return nextLoad(url, context);
}
