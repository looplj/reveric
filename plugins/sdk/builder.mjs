// Builds a plugin project into the package layout the Host loads, and packs
// it as an importable ZIP. Used by the reveric-plugin CLI and by Reveric's
// bundled plugins.
import { build } from "esbuild";
import { zipSync } from "fflate";
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import {
  cp,
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve, sep } from "node:path";
import { pageEntry, tsxPlugin } from "./tsx_transform.mjs";

const require = createRequire(import.meta.url);
const maxBundleBytes = 2 * 1024 * 1024;
const maxZipBytes = 10 * 1024 * 1024;
const maxExpandedBytes = 20 * 1024 * 1024;
const maxEntries = 500;

function fail(message) {
  throw new Error(`reveric-plugin: ${message}`);
}

// A relative path that stays inside the package.
function packagePath(path, what) {
  if (
    typeof path !== "string" ||
    path.startsWith("/") ||
    path.includes("\\") ||
    path.includes(":") ||
    path.split("/").some((part) => !part || part === "." || part === "..")
  )
    fail(`${what} must be a relative path inside the package: ${path}`);
  return path;
}

async function readManifest(root) {
  let manifest;
  try {
    manifest = JSON.parse(await readFile(join(root, "plugin.json"), "utf8"));
  } catch (error) {
    fail(`cannot read plugin.json: ${error.message}`);
  }
  if (!/^[a-z0-9]+(\.[a-z0-9-]+)+$/.test(manifest.id ?? ""))
    fail(`plugin.json id must look like vendor.name: ${manifest.id}`);
  if (typeof manifest.version !== "string" || !manifest.version)
    fail("plugin.json version is required");
  if (manifest.main !== "dist/index.js")
    fail('plugin.json main must be "dist/index.js"');
  return manifest;
}

function typecheck(root) {
  if (!existsSync(join(root, "tsconfig.json")))
    fail(
      'tsconfig.json is missing; extend "reveric-plugin-sdk/tsconfig.base.json"',
    );
  const tsc = require.resolve("typescript/bin/tsc");
  const result = spawnSync(process.execPath, [tsc, "--noEmit", "-p", root], {
    stdio: "inherit",
  });
  if (result.error) throw result.error;
  if (result.status !== 0) fail("type check failed");
}

async function writeBundle(file, contents, what) {
  if (file.endsWith(".js") && contents.byteLength > maxBundleBytes)
    fail(`${what} exceeds 2 MB`);
  await mkdir(dirname(file), { recursive: true });
  await writeFile(file, contents);
}

/**
 * Builds the plugin in `root` into `outDir` (default `<root>/build`):
 * `src/index.ts` → `dist/index.js`; each `reveric-tsx-v1` page whose source
 * is `dist/views/<name>.js` from `src/views/<name>.tsx`; `reveric-ui-v1` page
 * sources, the `views/` directory and declared migrations are copied as is.
 * Returns the manifest and the output directory.
 */
export async function buildPlugin({
  root = ".",
  outDir,
  typecheck: check = true,
  define = {},
} = {}) {
  root = resolve(root);
  outDir = resolve(outDir ?? join(root, "build"));
  const manifest = await readManifest(root);
  if (check) typecheck(root);
  await rm(outDir, { recursive: true, force: true });
  await mkdir(outDir, { recursive: true });

  const entry = await build({
    entryPoints: [join(root, "src/index.ts")],
    bundle: true,
    format: "iife",
    globalName: "__revericPlugin",
    minify: true,
    // Keep Markdown hard-break spaces escaped in generated string literals.
    supported: { "template-literal": false },
    platform: "neutral",
    mainFields: ["module", "main"],
    target: "es2020",
    charset: "utf8",
    legalComments: "eof",
    write: false,
    define,
  });
  await writeBundle(
    join(outDir, manifest.main),
    entry.outputFiles[0].contents,
    "dist/index.js",
  );

  for (const [id, page] of Object.entries(manifest.pages ?? {})) {
    const source = packagePath(page.source, `pages.${id}.source`);
    if (page.protocol === "reveric-tsx-v1") {
      const name = /^dist\/views\/([a-z][a-z0-9-]*)\.js$/.exec(source)?.[1];
      if (!name)
        fail(`pages.${id}.source must be dist/views/<name>.js: ${source}`);
      const input = join(root, "src/views", `${name}.tsx`);
      if (!existsSync(input)) fail(`missing page source src/views/${name}.tsx`);
      const view = await build({
        stdin: pageEntry(input),
        bundle: true,
        format: "iife",
        globalName: "__revericView",
        platform: "neutral",
        target: "es2020",
        charset: "utf8",
        sourcemap: true,
        sourcesContent: true,
        write: false,
        outfile: join(outDir, source),
        plugins: [tsxPlugin()],
      });
      for (const file of view.outputFiles)
        await writeBundle(file.path, file.contents, source);
    } else {
      await mkdir(dirname(join(outDir, source)), { recursive: true });
      await cp(join(root, source), join(outDir, source));
    }
  }
  if (existsSync(join(root, "views")))
    await cp(join(root, "views"), join(outDir, "views"), { recursive: true });
  for (const migration of manifest.database?.migrations ?? []) {
    const source = packagePath(migration.source, "migration source");
    if (!source.endsWith(".sql")) fail(`migration must be .sql: ${source}`);
    await mkdir(dirname(join(outDir, source)), { recursive: true });
    await cp(join(root, source), join(outDir, source));
  }
  await cp(join(root, "plugin.json"), join(outDir, "plugin.json"));
  return { manifest, outDir };
}

async function collect(dir, base = dir, files = {}) {
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) await collect(path, base, files);
    else
      files[relative(base, path).split(sep).join("/")] = await readFile(path);
  }
  return files;
}

/**
 * Builds the plugin and packs it as `<id>-<version>.zip` in `root`, or at
 * `outFile`, with plugin.json at the archive root. Returns the ZIP path.
 */
export async function packPlugin({
  root = ".",
  outFile,
  typecheck: check = true,
  define = {},
} = {}) {
  root = resolve(root);
  const temporary = await mkdtemp(join(tmpdir(), "reveric-plugin-"));
  try {
    const { manifest, outDir } = await buildPlugin({
      root,
      outDir: join(temporary, "package"),
      typecheck: check,
      define,
    });
    const files = await collect(outDir);
    const count = Object.keys(files).length;
    const expanded = Object.values(files).reduce((n, f) => n + f.byteLength, 0);
    if (count > maxEntries) fail(`package has ${count} files (max 500)`);
    if (expanded > maxExpandedBytes) fail("package exceeds 20 MB unpacked");
    const zip = zipSync(files, { level: 9 });
    if (zip.byteLength > maxZipBytes) fail("ZIP exceeds 10 MB");
    outFile = resolve(
      outFile ?? join(root, `${manifest.id}-${manifest.version}.zip`),
    );
    await mkdir(dirname(outFile), { recursive: true });
    await writeFile(outFile, zip);
    return outFile;
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
}
