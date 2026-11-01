import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { unzipSync } from "fflate";
import { buildPlugin, packPlugin } from "./builder.mjs";

const here = dirname(fileURLToPath(import.meta.url));

// Projects live under the workspace so "reveric-plugin-sdk" resolves like an
// installed dependency.
async function project(files) {
  const root = await mkdtemp(join(here, ".builder-test-"));
  for (const [path, contents] of Object.entries(files)) {
    if (contents === undefined) continue;
    await mkdir(dirname(join(root, path)), { recursive: true });
    await writeFile(
      join(root, path),
      typeof contents === "string" ? contents : JSON.stringify(contents),
    );
  }
  return root;
}

const manifest = {
  id: "example.hello",
  name: "Hello",
  version: "1.2.0",
  pluginApiVersion: "^1",
  main: "dist/index.js",
  database: {
    version: 1,
    migrations: [{ version: 1, source: "migrations/001.sql" }],
  },
  pages: {
    home: {
      title: "Home",
      location: "home.plugin",
      protocol: "reveric-tsx-v1",
      source: "dist/views/home.js",
    },
    info: {
      title: "Info",
      location: "home.plugin",
      protocol: "reveric-ui-v1",
      source: "views/info.json",
      actions: [],
    },
  },
};
const sources = {
  "plugin.json": manifest,
  "tsconfig.json": {
    extends: "reveric-plugin-sdk/tsconfig.base.json",
    include: ["src"],
  },
  "src/index.ts": `import { PluginError, type PluginSetup } from "reveric-plugin-sdk";
export function apply(setup: PluginSetup) {
  setup.tools.register({ name: "Hello", description: "Hi", inputSchema: { type: "object" },
    async handler(input) { if (!input) throw new PluginError("invalid_argument", "x"); return { ok: true }; } });
}`,
  "src/views/home.tsx": `import { Text, type PageContext } from "reveric-plugin-sdk/ui";
export default function Page(context: PageContext) { return <Text text={context.page.viewId} />; }`,
  "views/info.json": "[]",
  "views/card.json": "[]",
  "migrations/001.sql": "CREATE TABLE t (id TEXT PRIMARY KEY);",
};

test("builds entry, pages, views and migrations into the package layout", async () => {
  const root = await project(sources);
  try {
    const { outDir } = await buildPlugin({ root });
    for (const file of [
      "plugin.json",
      "dist/index.js",
      "dist/views/home.js",
      "dist/views/home.js.map",
      "views/info.json",
      "views/card.json",
      "migrations/001.sql",
    ])
      assert.ok(existsSync(join(outDir, file)), file);
    const entry = await readFile(join(outDir, "dist/index.js"), "utf8");
    assert.match(entry, /__revericPlugin/);
    const page = await readFile(join(outDir, "dist/views/home.js"), "utf8");
    assert.match(page, /var __revericView/);
    assert.match(page, /__revericUi\.mount/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("packs a ZIP with plugin.json at the root", async () => {
  const root = await project(sources);
  try {
    const file = await packPlugin({ root, typecheck: false });
    assert.equal(file, join(root, "example.hello-1.2.0.zip"));
    const entries = Object.keys(unzipSync(await readFile(file)));
    assert.ok(entries.includes("plugin.json"));
    assert.ok(entries.includes("dist/views/home.js"));
    assert.ok(entries.every((path) => !path.startsWith("build/")));
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("reports type errors and layout mistakes with actionable messages", async () => {
  const roots = [];
  try {
    const typeError = await project({
      ...sources,
      "src/index.ts": "export const apply: number = 'x';",
    });
    const wrongPage = await project({
      ...sources,
      "plugin.json": {
        ...manifest,
        pages: { home: { ...manifest.pages.home, source: "home.js" } },
      },
    });
    const noTsconfig = await project({
      ...sources,
      "tsconfig.json": undefined,
    });
    roots.push(typeError, wrongPage, noTsconfig);
    await assert.rejects(buildPlugin({ root: typeError }), /type check failed/);
    await assert.rejects(
      buildPlugin({ root: wrongPage, typecheck: false }),
      /dist\/views\/<name>\.js/,
    );
    await assert.rejects(
      buildPlugin({ root: noTsconfig }),
      /tsconfig\.base\.json/,
    );
  } finally {
    for (const root of roots) await rm(root, { recursive: true, force: true });
  }
});
