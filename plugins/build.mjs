import { build } from "esbuild";
import { buildPlugin } from "reveric-plugin-sdk/build";
import { readdir, readFile, mkdtemp, rm, stat } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { resolve, join, dirname } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";
const root = dirname(fileURLToPath(import.meta.url));
if (Number(process.versions.node.split(".")[0]) !== 22)
  throw new Error("Use Node.js 22 (plugins/.nvmrc)");
function run(args) {
  const result = spawnSync(process.execPath, args, {
    cwd: root,
    stdio: "inherit",
  });
  if (result.error) throw result.error;
  if (result.status !== 0)
    throw new Error(
      `Command failed: node ${args.join(" ")} (exit ${result.status})`,
    );
}
run(["sdk/generate_sqlite.mjs"]);
run(["node_modules/typescript/bin/tsc", "--noEmit"]);
const plugins = [];
for (const entry of await readdir(root, { withFileTypes: true })) {
  if (!entry.isDirectory() || ["node_modules", "sdk"].includes(entry.name))
    continue;
  const files = await readdir(join(root, entry.name));
  if (files.includes("plugin.json")) plugins.push(entry.name);
}
if (process.argv.includes("--test")) {
  const temporary = await mkdtemp(join(tmpdir(), "reveric-plugins-test-"));
  try {
    const tests = [];
    for (const plugin of plugins) {
      for (const file of await readdir(join(root, plugin, "test"))) {
        if (!file.endsWith(".test.ts")) continue;
        const output = join(
          temporary,
          `${plugin}-${file.replace(/\.ts$/, ".mjs")}`,
        );
        await build({
          entryPoints: [join(root, plugin, "test", file)],
          bundle: true,
          platform: "node",
          format: "esm",
          target: "node22",
          outfile: output,
          define: { "process.env.LOG_PERF": "false" },
        });
        tests.push(output);
      }
    }
    run([
      "--test",
      ...tests,
      "sdk/tsx_transform.test.mjs",
      "sdk/builder.test.mjs",
      "sdk/sqlite_runtime.test.mjs",
    ]);
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
} else {
  // Bundled plugins build exactly like third-party ones; only the output
  // directory differs. The workspace-wide tsc above already type-checked them.
  for (const plugin of plugins) {
    const { id } = JSON.parse(
      await readFile(join(root, plugin, "plugin.json"), "utf8"),
    );
    const { manifest, outDir } = await buildPlugin({
      root: join(root, plugin),
      outDir: resolve(root, "../assets/plugins", id),
      typecheck: false,
      define: { "process.env.LOG_PERF": "false" },
    });
    const { size } = await stat(join(outDir, manifest.main));
    console.log(`${manifest.id}: ${size} bytes`);
  }
}
