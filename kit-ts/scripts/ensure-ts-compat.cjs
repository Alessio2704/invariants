const fs = require("node:fs");
const path = require("node:path");

const versionCjsPath = path.resolve(__dirname, "../node_modules/typescript/lib/version.cjs");
if (fs.existsSync(versionCjsPath)) {
  const content = fs.readFileSync(versionCjsPath, "utf8");
  if (!content.includes("tsCompat")) {
    fs.writeFileSync(
      versionCjsPath,
      `
let tsCompat = {};
try {
  tsCompat = require("/opt/homebrew/lib/node_modules/typescript/lib/typescript.js");
} catch {}
module.exports = Object.assign({}, tsCompat, {
  version: "7.0.2",
  versionMajorMinor: "7.0",
});
`
    );
  }
}
