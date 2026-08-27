#!/usr/bin/env node

// Rebuild lobby-decoder.js from an exact OpenFrontIO checkout.
//
// Usage:
//   node scripts/build-lobby-decoder.mjs /path/to/OpenFrontIO <git-commit>
//
// OpenFront's zbin wire format has no version marker. The checkout must be at
// the commit deployed by openfront.io (window.BOOTSTRAP_CONFIG.gitCommit), not
// merely the latest main branch.

import { execFileSync } from "node:child_process";
import { access, readFile, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const [, , sourceArgument, expectedCommit] = process.argv;
if (!sourceArgument || !expectedCommit) {
  console.error(
    "Usage: node scripts/build-lobby-decoder.mjs /path/to/OpenFrontIO <git-commit>",
  );
  process.exit(2);
}

const source = path.resolve(sourceArgument);
const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const output = path.resolve(scriptDir, "..", "lobby-decoder.js");
const actualCommit = execFileSync("git", ["-C", source, "rev-parse", "HEAD"], {
  encoding: "utf8",
}).trim();

if (actualCommit !== expectedCommit) {
  throw new Error(
    `OpenFront checkout is at ${actualCommit}, expected ${expectedCommit}`,
  );
}

await access(path.join(source, "src/core/ZbinWire.ts"));
const requireFromOpenFront = createRequire(
  path.join(source, "package.json"),
);
const esbuild = requireFromOpenFront("esbuild");

const utf8Polyfill = `
globalThis.TextEncoder ??= class TextEncoder {
  encode(value) {
    const string = unescape(encodeURIComponent(String(value)));
    const result = new Uint8Array(string.length);
    for (let i = 0; i < string.length; i++) result[i] = string.charCodeAt(i);
    return result;
  }
};
globalThis.TextDecoder ??= class TextDecoder {
  decode(value) {
    const bytes = new Uint8Array(value);
    let string = "";
    for (let i = 0; i < bytes.length; i += 8192) {
      string += String.fromCharCode(...bytes.subarray(i, i + 8192));
    }
    return decodeURIComponent(escape(string));
  }
};
`;

await esbuild.build({
  stdin: {
    contents: `
      import { decodeLobbyMessage } from "./src/core/ZbinWire.ts";
      globalThis.OPENFRONT_DECODER_COMMIT = ${JSON.stringify(expectedCommit)};
      globalThis.decodeLobbyFrame = function (bytes) {
        return JSON.stringify(decodeLobbyMessage(Uint8Array.from(bytes)));
      };
    `,
    resolveDir: source,
    sourcefile: "lobby-decoder-entry.ts",
    loader: "ts",
  },
  alias: { resources: path.join(source, "resources") },
  banner: { js: utf8Polyfill },
  bundle: true,
  format: "iife",
  legalComments: "inline",
  minify: true,
  nodePaths: [path.join(source, "node_modules")],
  outfile: output,
  platform: "browser",
  target: ["safari16"],
});

// Some upstream license comments contain trailing spaces. Keep the checked-in
// generated artifact friendly to `git diff --check` without changing content.
const bundled = await readFile(output, "utf8");
await writeFile(output, bundled.replace(/[\t ]+$/gm, ""));

console.log(`Built ${output} from OpenFrontIO ${expectedCommit}`);
