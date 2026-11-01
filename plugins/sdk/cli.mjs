#!/usr/bin/env node
// reveric-plugin build | pack — see README.md.
import { stat } from "node:fs/promises";
import { relative } from "node:path";
import { buildPlugin, packPlugin } from "./builder.mjs";

const usage = `Usage:
  reveric-plugin build [dir] [--out <dir>] [--no-typecheck]
  reveric-plugin pack  [dir] [--out <file.zip>] [--no-typecheck]

build  Type-checks and builds the plugin in dir (default .) into <dir>/build.
pack   Builds and packs the plugin as <id>-<version>.zip for import.`;

const [command, ...rest] = process.argv.slice(2);
const options = { root: ".", typecheck: true };
for (let i = 0; i < rest.length; i++) {
  const arg = rest[i];
  if (arg === "--out") options.out = rest[++i];
  else if (arg === "--no-typecheck") options.typecheck = false;
  else if (!arg.startsWith("-")) options.root = arg;
  else {
    console.error(`Unknown option ${arg}\n\n${usage}`);
    process.exit(2);
  }
}
try {
  if (command === "build") {
    const { manifest, outDir } = await buildPlugin({
      root: options.root,
      outDir: options.out,
      typecheck: options.typecheck,
    });
    console.log(
      `${manifest.id}: built ${relative(process.cwd(), outDir) || "."}`,
    );
  } else if (command === "pack") {
    const file = await packPlugin({
      root: options.root,
      outFile: options.out,
      typecheck: options.typecheck,
    });
    const { size } = await stat(file);
    console.log(`packed ${relative(process.cwd(), file)} (${size} bytes)`);
  } else {
    console.log(usage);
    process.exit(command === "--help" || command === "-h" ? 0 : 2);
  }
} catch (error) {
  console.error(error.message);
  process.exit(1);
}
