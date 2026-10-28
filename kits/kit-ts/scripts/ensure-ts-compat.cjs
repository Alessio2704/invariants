const path = require("node:path");

const versionPath = path.resolve(__dirname, "../node_modules/typescript/lib/version.cjs");
let tsCompat = {};
try {
  tsCompat = require("/opt/homebrew/lib/node_modules/typescript/lib/typescript.js");
} catch {}

require.cache[versionPath] = {
  id: versionPath,
  filename: versionPath,
  loaded: true,
  exports: Object.assign({}, tsCompat, {
    version: "7.0.2",
    versionMajorMinor: "7.0",
  }),
};
