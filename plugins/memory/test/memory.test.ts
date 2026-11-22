import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";
import {
  create,
  forgetFromTool,
  list,
  listTopics,
  pendingSuggestions,
  prompt,
  resolveSuggestion,
  saveFromTool,
  syncMemoryBadge,
  update,
} from "../src/data";
import { extractJsonArray, organize } from "../src/organize";
import type { Json, PluginSqlite, TaskContext } from "reveric-plugin-sdk";

function wrapSqlite(raw: DatabaseSync): PluginSqlite {
  const sqlite: PluginSqlite = {
    async query({ sql, params = [] }) {
      return raw.prepare(sql).all(...params) as never;
    },
    async execute({ sql, params = [] }) {
      const result = raw.prepare(sql).run(...params);
      return {
        changes: Number(result.changes),
        lastInsertRowId: BigInt(result.lastInsertRowid),
      };
    },
    async transaction(statements) {
      raw.exec("BEGIN");
      try {
        const result = [];
        for (const s of statements) result.push(await sqlite.execute(s));
        raw.exec("COMMIT");
        return result;
      } catch (e) {
        raw.exec("ROLLBACK");
        throw e;
      }
    },
  };
  return sqlite;
}

function fixture(
  options: {
    settings?: Record<string, Json>;
    trigger?: "scheduled" | "manual";
    aiResponder?: (rows: Record<string, unknown>[]) => string | Promise<string>;
  } = {},
) {
  const raw = new DatabaseSync(":memory:");
  raw.exec(readFileSync("memory/migrations/001.sql", "utf8"));
  raw.exec(readFileSync("memory/migrations/002.sql", "utf8"));
  const sqlite = wrapSqlite(raw);
  const storage = new Map<string, Json>();
  let calls = 0;
  const models: unknown[] = [];
  const settings = options.settings ?? {};
  const respond =
    options.aiResponder ??
    ((rows) =>
      JSON.stringify(
        rows.slice(0, 1).map((r) => ({
          kind: "refine",
          reason: "精简表述",
          sources: [{ id: r.id, revision: r.revision }],
          content: "Refined " + r.content,
          topic: r.topic || "文风",
        })),
      ));

  const context = {
    runId: "run",
    trigger: options.trigger ?? "manual",
    scheduledAt: 1,
    sqlite,
    storage: {
      get: async (k: string) => storage.get(k) ?? null,
      set: async (k: string, v: Json) => {
        storage.set(k, v);
      },
      remove: async (k: string) => {
        storage.delete(k);
      },
    },
    settings: { get: async (k: string) => settings[k] ?? null },
    ai: {
      generateText: async ({
        prompt: promptText,
        providerId,
        model,
      }: {
        prompt: string;
        providerId?: string;
        model?: string;
      }) => {
        calls++;
        models.push(providerId === undefined ? null : { providerId, model });
        const parsed = JSON.parse(promptText) as Record<string, unknown>[];
        return { text: await respond(parsed) };
      },
    },
  } as unknown as TaskContext;

  return {
    raw,
    sqlite,
    storage,
    context,
    models,
    get calls() {
      return calls;
    },
  };
}

function rawCount(db: DatabaseSync, table: string) {
  return Number(db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get()!.n);
}

test("002.sql migrates legacy work-scoped memories into global topic-based memories", async () => {
  const raw = new DatabaseSync(":memory:");
  try {
    raw.exec(readFileSync("memory/migrations/001.sql", "utf8"));
    raw
      .prepare(
        "INSERT INTO memories (id, work_id, content, category, priority, enabled, revision, created_at, updated_at, deleted_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      )
      .run(
        "old-1",
        "work-a",
        "保留原作品偏好",
        "preference",
        1,
        1,
        2,
        10,
        20,
        null,
      );
    raw
      .prepare(
        "INSERT INTO memories (id, work_id, content, category, priority, enabled, revision, created_at, updated_at, deleted_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      )
      .run("old-2", null, "保留原全局事实", "fact", 0, 1, 1, 11, 21, null);
    raw.exec(readFileSync("memory/migrations/002.sql", "utf8"));

    const sqlite = wrapSqlite(raw);
    const result = await list(sqlite);
    assert.equal(result.items.length, 2);
    assert.equal(result.items[0].id, "old-1");
    assert.equal(result.items[0].topic, "偏好");
    assert.equal(result.items[0].revision, 2);
    assert.equal(result.items[1].id, "old-2");
    assert.equal(result.items[1].topic, "事实");
    assert.equal(rawCount(raw, "suggestions"), 0);
  } finally {
    raw.close();
  }
});

test("saveFromTool, forgetFromTool, free topics, similarity hint and grouped prompt", async () => {
  const f = fixture();
  try {
    const first = await saveFromTool(f.sqlite, {
      content: "描写偏克制，避免使用空气仿佛凝固了这类网文套话",
      topic: "文风",
      priority: 1,
    });
    assert.equal(first.action, "created");
    assert.equal(first.memory.topic, "文风");
    assert.equal(first.similar, undefined);

    const second = await saveFromTool(f.sqlite, {
      content: "描写克制，不要用空气仿佛凝固了这种网文套话",
      topic: "写作风格",
    });
    assert.equal(second.action, "created");
    assert.ok(second.similar && second.similar.length === 1);
    assert.equal(second.similar[0].id, first.memory.id);

    const updated = await saveFromTool(f.sqlite, {
      id: first.memory.id,
      content: "行文克制留白，禁止使用网文套话",
      topic: "文风",
    });
    assert.equal(updated.action, "updated");
    assert.equal(updated.memory.revision, 2);

    assert.deepEqual(await listTopics(f.sqlite), ["写作风格", "文风"]);
    assert.equal(
      (await list(f.sqlite, { query: "克制 套话" })).items.length,
      2,
    );

    const rendered = await prompt(f.sqlite);
    assert.match(rendered.text, /\[文风\]/);
    assert.match(rendered.text, new RegExp(`\\[${first.memory.id}\\]`));
    assert.match(rendered.text, /行文克制留白/);

    await forgetFromTool(f.sqlite, { id: second.memory.id });
    assert.equal((await list(f.sqlite)).items.length, 1);

    await update(f.sqlite, {
      id: first.memory.id,
      revision: 2,
      enabled: false,
    });
    await assert.rejects(
      update(f.sqlite, { id: first.memory.id, revision: 2, content: "stale" }),
      /changed/,
    );
    assert.equal((await prompt(f.sqlite)).text, "");
    assert.equal(rawCount(f.raw, "memories"), 2);
  } finally {
    f.raw.close();
  }
});

test("dream consolidation supports merge, archive, insight, override apply, and stale gating", async () => {
  const f = fixture({
    aiResponder: (rows) => {
      const a = rows.find((r) => String(r.content).includes("嘴角"))!;
      const b = rows.find((r) => String(r.content).includes("空气"))!;
      const c = rows.find((r) => String(r.content).includes("林渊"))!;
      return [
        "```json",
        JSON.stringify([
          {
            kind: "merge",
            reason: "两条都在强调禁用网文套话，可以合并",
            sources: [
              { id: a.id, revision: a.revision },
              { id: b.id, revision: b.revision },
            ],
            content: "描写保持克制，避免油腻动作与常见网文套话",
            topic: "文风",
            priority: 1,
          },
          {
            kind: "archive",
            reason: "疑似单部作品具体角色设定，非跨作品偏好",
            sources: [{ id: c.id, revision: c.revision }],
          },
          {
            kind: "insight",
            reason: "整体审美偏向冷峻留白",
            sources: [
              { id: a.id, revision: a.revision },
              { id: b.id, revision: b.revision },
            ],
            content: "整体叙事气质偏冷峻克制，偏好留白胜过直白解释",
            topic: "叙事",
          },
        ]),
        "```",
      ].join("\n");
    },
  });
  try {
    const a = await create(f.sqlite, {
      content: "不要写嘴角勾起一抹弧度",
      topic: "文风",
      priority: 1,
    });
    const b = await create(f.sqlite, {
      content: "少用空气仿佛凝固了这种套话",
      topic: "写作风格",
    });
    const c = await create(f.sqlite, {
      content: "主角林渊左眼失明",
      topic: "",
    });

    await organize(f.context);
    // Re-running with same state and manual trigger still deduplicates by fingerprint.
    await organize(f.context);
    assert.equal(f.calls, 2);
    const { items: pending } = await pendingSuggestions(f.sqlite);
    assert.equal(pending.length, 3);

    const mergeItem = pending.find((p) => p.kind === "merge")!;
    const archiveItem = pending.find((p) => p.kind === "archive")!;
    const insightItem = pending.find((p) => p.kind === "insight")!;

    // Apply insight with user edit override first while a and b are still active.
    await resolveSuggestion(f.sqlite, insightItem.id, true, {
      content: "偏爱冷峻克制与留白表达",
      topic: "审美",
    });
    // Apply merge: creates 1 new memory and supersedes a and b.
    await resolveSuggestion(f.sqlite, mergeItem.id, true);
    // Apply archive on c.
    await resolveSuggestion(f.sqlite, archiveItem.id, true);

    const active = await list(f.sqlite, { view: "active" });
    assert.equal(active.items.length, 2);
    assert.ok(active.items.some((m) => m.content === "偏爱冷峻克制与留白表达"));
    assert.ok(
      active.items.some(
        (m) => m.content === "描写保持克制，避免油腻动作与常见网文套话",
      ),
    );

    const history = await list(f.sqlite, { view: "history" });
    assert.equal(history.items.length, 3);
    const oldA = history.items.find((m) => m.id === a.id)!;
    const oldB = history.items.find((m) => m.id === b.id)!;
    const oldC = history.items.find((m) => m.id === c.id)!;
    assert.equal(oldA.status, "superseded");
    assert.equal(oldB.status, "superseded");
    assert.ok(oldA.superseded_by && oldA.superseded_by === oldB.superseded_by);
    assert.equal(oldC.status, "archived");
  } finally {
    f.raw.close();
  }
});

test("scheduled dream skips when unchanged or below change threshold", async () => {
  const f = fixture({ trigger: "scheduled" });
  try {
    await create(f.sqlite, { content: "偏好一", topic: "文风" });
    await organize(f.context);
    assert.equal(f.calls, 1);

    // No change -> 0-token skip
    await organize(f.context);
    assert.equal(f.calls, 1);

    // Only 1 new item (< 3) -> still skip on scheduled trigger
    await create(f.sqlite, { content: "偏好二", topic: "文风" });
    await organize(f.context);
    assert.equal(f.calls, 1);

    // Three new entries since the previous snapshot trigger another run.
    await create(f.sqlite, { content: "偏好三", topic: "文风" });
    await create(f.sqlite, { content: "偏好四", topic: "文风" });
    await organize(f.context);
    assert.equal(f.calls, 2);
  } finally {
    f.raw.close();
  }
});

test("scheduled dream includes preference edits made during the previous model call", async () => {
  const revisions: unknown[][] = [];
  const f = fixture({
    trigger: "scheduled",
    async aiResponder(rows) {
      revisions.push(rows.map((row) => row.revision));
      if (revisions.length === 1) {
        for (const row of rows) {
          await update(f.sqlite, {
            id: String(row.id),
            revision: Number(row.revision),
            content: `${row.content}，已更新`,
          });
        }
      }
      return "[]";
    },
  });
  try {
    for (const content of ["偏好一", "偏好二", "偏好三"]) {
      await create(f.sqlite, { content });
    }
    await organize(f.context);
    await organize(f.context);
    await organize(f.context);
    assert.deepEqual(revisions, [
      [1, 1, 1],
      [2, 2, 2],
    ]);
  } finally {
    f.raw.close();
  }
});

test("prompt budget caps entries and reports overflow, and extractJsonArray handles fences", async () => {
  const f = fixture();
  try {
    for (let i = 0; i < 20; i++) {
      await create(f.sqlite, {
        content: `偏好${i}：` + "中".repeat(120),
        topic: i % 2 === 0 ? "文风" : "节奏",
      });
    }
    const view = await prompt(f.sqlite);
    assert.ok(view.count > 0 && view.count < 20);
    assert.equal(view.overflow, 20 - view.count);
    assert.ok(view.used <= view.budget);
    assert.doesNotMatch(view.text, /超出注入预算/);
    assert.deepEqual(extractJsonArray("```json\n[]\n```"), []);
  } finally {
    f.raw.close();
  }
});

test("suggestion pages load the matching sources and resolve an item on a later page", async () => {
  const f = fixture();
  try {
    const original = "长".repeat(4000);
    const memory = await create(f.sqlite, { content: original });
    const addSuggestion = f.raw.prepare(`INSERT INTO suggestions
      (id, kind, reason, fingerprint, run_id, created_at, updated_at)
      VALUES (?, 'archive', '理由', ?, 'run', ?, ?)`);
    const link = f.raw.prepare(`INSERT INTO suggestion_sources
      (suggestion_id, memory_id, source_revision) VALUES (?, ?, 1)`);
    for (let i = 0; i < 6; i++) {
      const id = `suggestion_${i}`;
      addSuggestion.run(id, id, i, i);
      link.run(id, memory.id);
    }
    const first = await pendingSuggestions(f.sqlite);
    assert.equal(first.items.length, 5);
    assert.equal(first.hasMore, true);
    const second = await pendingSuggestions(f.sqlite, 5);
    assert.equal(second.hasMore, false);
    assert.deepEqual(
      second.items.map((item) => item.id),
      ["suggestion_0"],
    );
    const [source] = second.items[0].sources;
    assert.equal(source.memory_id, memory.id);
    assert.equal(source.content_truncated, true);
    assert.ok(source.content && original.startsWith(source.content));
    assert.equal(
      (await resolveSuggestion(f.sqlite, "suggestion_0", true)).status,
      "applied",
    );
    assert.equal(
      (await list(f.sqlite, { view: "history" })).items[0].content,
      original,
    );
  } finally {
    f.raw.close();
  }
});

test("organize uses configured model, else default chat model", async () => {
  const chosen = fixture({
    settings: { organizeModel: { providerId: "openai", model: "gpt-5" } },
  });
  const fallback = fixture();
  try {
    await create(chosen.sqlite, { content: "偏好甲" });
    await create(fallback.sqlite, { content: "偏好乙" });
    await organize(chosen.context);
    await organize(fallback.context);
    assert.deepEqual(chosen.models, [{ providerId: "openai", model: "gpt-5" }]);
    assert.deepEqual(fallback.models, [null]);
  } finally {
    chosen.raw.close();
    fallback.raw.close();
  }
});

test("syncMemoryBadge prioritizes pending suggestions, falls back to overflow warning dot, and clears when clean", async () => {
  const f = fixture();
  const badgeKey = "__system_internal_page_badge:manage";
  try {
    // Initially empty -> clears badge.
    assert.equal(await syncMemoryBadge(f.sqlite, f.context.storage), null);
    assert.equal(f.storage.has(badgeKey), false);

    // Overflow without pending suggestions -> warning dot.
    const createdIds: string[] = [];
    for (let i = 0; i < 12; i++) {
      const m = await create(f.sqlite, {
        content: `偏好${i}：` + "字".repeat(120),
        topic: "文风",
      });
      createdIds.push(m.id);
    }
    const overflowBadge = await syncMemoryBadge(f.sqlite, f.context.storage);
    assert.deepEqual(overflowBadge, { dot: true, tone: "warning" });
    assert.deepEqual(f.storage.get(badgeKey), { dot: true, tone: "warning" });

    // Running dream consolidation produces a pending suggestion -> takes priority with accent count.
    await organize(f.context);
    assert.deepEqual(f.storage.get(badgeKey), { count: 1, tone: "accent" });

    // Resolving the suggestion drops back to the warning dot while overflow remains.
    const { items } = await pendingSuggestions(f.sqlite);
    await resolveSuggestion(f.sqlite, items[0].id, false);
    assert.deepEqual(await syncMemoryBadge(f.sqlite, f.context.storage), {
      dot: true,
      tone: "warning",
    });

    // Removing overflow entries clears the badge completely.
    for (const memoryId of createdIds) {
      await forgetFromTool(f.sqlite, { id: memoryId });
    }
    assert.equal(await syncMemoryBadge(f.sqlite, f.context.storage), null);
    assert.equal(f.storage.has(badgeKey), false);
  } finally {
    f.raw.close();
  }
});
