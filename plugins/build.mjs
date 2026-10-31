import { build } from "esbuild";
import { tsxPlugin } from "./sdk/tsx_transform.mjs";
import {
  readdir,
  readFile,
  mkdir,
  writeFile,
  copyFile,
  mkdtemp,
  rm,
} from "node:fs/promises";
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
    run(["--test", ...tests, "sdk/tsx_transform.test.mjs", "sdk/sqlite_runtime.test.mjs"]);
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
} else {
  for (const plugin of plugins) {
    const manifestPath = join(root, plugin, "plugin.json");
    const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
    if (
      !/^[a-z0-9]+(\.[a-z0-9-]+)+$/.test(manifest.id) ||
      manifest.main !== "dist/index.js"
    )
      throw new Error(`Invalid bundled manifest: ${plugin}`);
    const result = await build({
      entryPoints: [join(root, plugin, "src/index.ts")],
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
      define: { "process.env.LOG_PERF": "false" },
    });
    const bundle = result.outputFiles[0].contents;
    if (bundle.byteLength > 2 * 1024 * 1024)
      throw new Error(`${manifest.id} exceeds 2 MB`);
    const output = resolve(root, "../assets/plugins", manifest.id);
    await mkdir(join(output, "dist"), { recursive: true });
    await writeFile(join(output, manifest.main), bundle);
    const buildConfigPath=join(root,plugin,'build.json');
    let config={};
    try {config=JSON.parse(await readFile(buildConfigPath,'utf8'));}
    catch(error) {if(error.code!=='ENOENT') throw error;}
    for(const [name,entry] of Object.entries(config.views??{})) {
      if(!/^[a-z][a-z0-9-]*$/.test(name)||typeof entry!=='string'||!entry.startsWith('src/views/')||!entry.endsWith('.tsx')||entry.split('/').includes('..')||entry.includes('\\')) throw new Error('Invalid view build entry');
      await mkdir(join(output,'dist/views'),{recursive:true});
      const view=await build({entryPoints:[join(root,plugin,entry)],bundle:true,format:'iife',globalName:'__revericView',
        platform:'neutral',target:'es2020',charset:'utf8',sourcemap:true,sourcesContent:true,write:false,
        outfile:join(output,'dist/views',name+'.js'),plugins:[tsxPlugin()]});
      for(const file of view.outputFiles) {
        if(file.path.endsWith('.js')&&file.contents.byteLength>2*1024*1024) throw new Error('View exceeds 2 MB');
        await writeFile(file.path,file.contents);
      }
    }
    for (const migration of manifest.database?.migrations ?? []) {
      const source = migration.source;
      if (typeof source !== 'string' || !source.endsWith('.sql') || source.startsWith('/') || source.includes('\\') || source.includes(':') || source.split('/').some(part => !part || part === '..' || part === '.')) throw new Error('Invalid migration source');
      await mkdir(dirname(join(output, source)), {recursive:true});
      await copyFile(join(root,plugin,source),join(output,source));
    }
    await copyFile(manifestPath, join(output, "plugin.json"));
    console.log(`${manifest.id}: ${bundle.byteLength} bytes`);
  }
}
