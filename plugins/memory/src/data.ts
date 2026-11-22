import {
  PluginError,
  setPageBadge,
  type JsonObject,
  type PageBadge,
  type PluginSqlite,
  type PluginStorage,
  type SqlStatement,
  type SqlValue,
} from "reveric-plugin-sdk";

export const suggestionKinds = [
  "conflict",
  "merge",
  "archive",
  "refine",
  "insight",
] as const;
export type SuggestionKind = (typeof suggestionKinds)[number];

export const memoryStatuses = ["active", "superseded", "archived"] as const;
export type MemoryStatus = (typeof memoryStatuses)[number];

export interface Memory {
  id: string;
  content: string;
  topic: string;
  priority: number;
  enabled: number;
  status: MemoryStatus;
  superseded_by: string | null;
  revision: number;
  created_at: number;
  updated_at: number;
  deleted_at: number | null;
}

export interface SuggestionSourceView {
  memory_id: string;
  source_revision: number;
  current_revision: number | null;
  current_status: string | null;
  deleted_at: number | null;
  content: string | null;
  content_truncated: boolean;
  topic: string;
  priority: number;
}

export interface SuggestionView {
  id: string;
  kind: SuggestionKind;
  reason: string;
  proposed_content: string | null;
  proposed_topic: string;
  proposed_priority: number | null;
  fingerprint: string;
  run_id: string;
  status: string;
  created_at: number;
  updated_at: number;
  stale: boolean;
  sources: SuggestionSourceView[];
}

export const PROMPT_CHAR_BUDGET = 1000;
export const MEMORY_PAGE_SIZE = 20;
export const SUGGESTION_PAGE_SIZE = 5;
export const MANAGE_PAGE_ID = "manage";
const SOURCE_PREVIEW_LENGTH = 120;

export function fail(code: string, message: string): never {
  throw new PluginError(code, message);
}

export function id(prefix = "m") {
  const time = Date.now().toString(36).slice(-4);
  const rand = Math.random().toString(36).slice(2, 6);
  return `${prefix}_${time}${rand}`;
}

export const now = () => Math.floor(Date.now() / 1000);

export function normalizeTopic(value: unknown): string {
  if (value === undefined || value === null) return "";
  if (typeof value !== "string") {
    fail("invalid_argument", "topic must be a string");
  }
  const trimmed = value.trim();
  if (trimmed.length > 40) {
    fail("invalid_argument", "topic must be at most 40 characters");
  }
  return trimmed;
}

export function checked(input: JsonObject) {
  const content = input.content;
  const topic = normalizeTopic(input.topic);
  const priority = input.priority ?? 0;
  const enabled = input.enabled ?? true;
  if (
    typeof content !== "string" ||
    !content.trim() ||
    content.trim().length > 4000
  ) {
    fail("invalid_argument", "content must contain 1–4000 characters");
  }
  if (priority !== 0 && priority !== 1) {
    fail("invalid_argument", "priority must be 0 or 1");
  }
  if (typeof enabled !== "boolean") {
    fail("invalid_argument", "enabled must be boolean");
  }
  return {
    content: content.trim(),
    topic,
    priority: priority as number,
    enabled: enabled ? 1 : 0,
  };
}

function ngrams(text: string): Set<string> {
  const clean = text
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim();
  const out = new Set<string>();
  for (const part of clean.split(/\s+/)) {
    if (!part) continue;
    if (/^[a-z0-9]+$/i.test(part)) {
      if (part.length >= 2) out.add(part);
      continue;
    }
    if (part.length <= 2) {
      out.add(part);
      continue;
    }
    for (let i = 0; i < part.length - 1; i++) {
      out.add(part.slice(i, i + 2));
    }
  }
  return out;
}

export function textSimilarity(a: string, b: string): number {
  const setA = ngrams(a);
  const setB = ngrams(b);
  if (setA.size === 0 || setB.size === 0) return 0;
  let overlap = 0;
  for (const token of setA) {
    if (setB.has(token)) overlap++;
  }
  return overlap / Math.min(setA.size, setB.size);
}

export async function findSimilar(
  db: Pick<PluginSqlite, "query">,
  content: string,
  excludeId?: string,
) {
  const rows = (await db.query({
    sql: "SELECT id, content, topic, priority FROM memories WHERE deleted_at IS NULL AND status = 'active' LIMIT 200",
  })) as unknown as Pick<Memory, "id" | "content" | "topic" | "priority">[];
  return rows
    .filter((row) => row.id !== excludeId)
    .map((row) => ({
      row,
      score: textSimilarity(content, row.content),
    }))
    .filter((entry) => entry.score >= 0.4)
    .sort((a, b) => b.score - a.score)
    .slice(0, 3)
    .map(({ row }) => ({
      id: row.id,
      topic: row.topic,
      content: row.content,
    }));
}

export async function get(db: Pick<PluginSqlite, "query">, memoryId: unknown) {
  if (typeof memoryId !== "string" || !memoryId.trim()) {
    fail("invalid_argument", "id is required");
  }
  const rows = await db.query({
    sql: "SELECT * FROM memories WHERE id = ? AND deleted_at IS NULL",
    params: [memoryId.trim()],
  });
  if (!rows.length) fail("not_found", "Memory not found");
  return rows[0] as unknown as Memory;
}

export async function listTopics(
  db: Pick<PluginSqlite, "query">,
): Promise<string[]> {
  const rows = await db.query({
    sql: "SELECT DISTINCT topic FROM memories WHERE deleted_at IS NULL AND topic != '' ORDER BY topic",
  });
  return rows.map((row) => String(row.topic));
}

export async function list(
  db: Pick<PluginSqlite, "query">,
  input: {
    query?: string;
    topic?: string;
    view?: "active" | "history" | "all";
    limit?: number;
    offset?: number;
  } = {},
) {
  const query = typeof input.query === "string" ? input.query.trim() : "";
  const topic = typeof input.topic === "string" ? input.topic.trim() : "";
  const view = input.view ?? "active";
  const limit = input.limit ?? MEMORY_PAGE_SIZE;
  const offset = input.offset ?? 0;
  if (
    !["active", "history", "all"].includes(view) ||
    query.length > 200 ||
    topic.length > 40 ||
    !Number.isInteger(limit) ||
    limit < 1 ||
    limit > 50 ||
    !Number.isInteger(offset) ||
    offset < 0
  ) {
    fail("invalid_argument", "Invalid search filters or pagination");
  }
  const statusClause =
    view === "active"
      ? "status = 'active'"
      : view === "history"
        ? "status IN ('archived', 'superseded')"
        : "1 = 1";
  const terms = query ? query.split(/\s+/) : [];
  const hits = terms
    .map(() => "(instr(lower(topic || ' ' || content), lower(?)) > 0)")
    .join(" + ");
  const base = `SELECT *${hits ? `, ${hits} AS hits` : ""} FROM memories
    WHERE deleted_at IS NULL AND ${statusClause} AND (? = '' OR topic = ?)`;
  const rows = (await db.query({
    sql: `SELECT * FROM (${base})${hits ? " WHERE hits > 0" : ""}
      ORDER BY ${hits ? "hits DESC, " : ""}priority DESC, updated_at DESC, id
      LIMIT ? OFFSET ?`,
    params: [...terms, topic, topic, limit + 1, offset],
  })) as unknown as (Memory & { hits?: number })[];
  return {
    items: rows.slice(0, limit).map(({ hits: _hits, ...memory }) => memory),
    hasMore: rows.length > limit,
  };
}

export async function create(db: PluginSqlite, input: JsonObject) {
  const value = checked(input);
  const key = id("m");
  const time = now();
  await db.execute({
    sql: "INSERT INTO memories (id, content, topic, priority, enabled, status, superseded_by, revision, created_at, updated_at) VALUES (?, ?, ?, ?, ?, 'active', NULL, 1, ?, ?)",
    params: [
      key,
      value.content,
      value.topic,
      value.priority,
      value.enabled,
      time,
      time,
    ],
  });
  return get(db, key);
}

export async function update(
  db: PluginSqlite,
  input: JsonObject,
  options: { remove?: boolean; requireRevision?: boolean } = {},
) {
  const original = await get(db, input.id);
  const requireRevision = options.requireRevision ?? true;
  if (requireRevision) {
    if (!Number.isInteger(input.revision) || Number(input.revision) < 1) {
      fail("invalid_argument", "revision is required");
    }
  }
  const remove = options.remove ?? false;
  const nextStatus =
    input.status !== undefined ? String(input.status) : original.status;
  if (!memoryStatuses.includes(nextStatus as MemoryStatus)) {
    fail("invalid_argument", "Invalid status");
  }
  const value = remove
    ? {
        content: original.content,
        topic: original.topic,
        priority: original.priority,
        enabled: original.enabled,
      }
    : checked({
        content: original.content,
        topic: original.topic,
        priority: original.priority,
        enabled: original.enabled === 1,
        ...input,
      });
  const nextEnabled = nextStatus === "active" ? value.enabled : 0;
  const nextSupersededBy =
    nextStatus === "active" ? null : original.superseded_by;
  const time = now();
  const whereRevision = requireRevision ? " AND revision = ?" : "";
  const params = [
    value.content,
    value.topic,
    value.priority,
    nextEnabled,
    nextStatus,
    nextSupersededBy,
    time,
    remove ? time : null,
    original.id,
    ...(requireRevision ? [Number(input.revision)] : []),
  ];
  const result = await db.execute({
    sql: `UPDATE memories SET content = ?, topic = ?, priority = ?, enabled = ?, status = ?, superseded_by = ?, revision = revision + 1, updated_at = ?, deleted_at = ? WHERE id = ? AND deleted_at IS NULL${whereRevision}`,
    params,
  });
  if (result.changes !== 1) {
    fail("conflict", "Memory changed; refresh before editing");
  }
  return remove ? { id: original.id, deleted: true } : get(db, original.id);
}

/** Agent tool entry: create when id is absent, update in place when id is provided. */
export async function saveFromTool(db: PluginSqlite, input: JsonObject) {
  if (
    input.id !== undefined &&
    input.id !== null &&
    String(input.id).trim() !== ""
  ) {
    const existing = await get(db, input.id);
    const updated = (await update(
      db,
      {
        id: existing.id,
        content: input.content ?? existing.content,
        topic: input.topic !== undefined ? input.topic : existing.topic,
        priority:
          input.priority !== undefined ? input.priority : existing.priority,
        enabled:
          input.enabled !== undefined ? input.enabled : existing.enabled === 1,
        status: "active",
      },
      { requireRevision: false },
    )) as Memory;
    return { action: "updated", memory: updated };
  }
  const value = checked(input);
  const similar = await findSimilar(db, value.content);
  const created = await create(db, {
    content: value.content,
    topic: value.topic,
    priority: value.priority,
    enabled: value.enabled === 1,
  });
  return {
    action: "created",
    memory: created,
    ...(similar.length ? { similar } : {}),
  };
}

/** Agent tool entry: soft-delete a preference by id. */
export async function forgetFromTool(db: PluginSqlite, input: JsonObject) {
  return update(db, { id: input.id }, { remove: true, requireRevision: false });
}

export async function prompt(db: Pick<PluginSqlite, "query">) {
  const where = "deleted_at IS NULL AND status = 'active' AND enabled = 1";
  const [totals, rows] = await Promise.all([
    db.query({ sql: `SELECT COUNT(*) AS total FROM memories WHERE ${where}` }),
    db.query({
      // Cap the encoded bytes as well so the worst case fits the 1 MB bridge.
      sql: `SELECT id, content, topic, priority FROM memories WHERE ${where}
        AND length(content) <= ? AND length(CAST(json_quote(content) AS BLOB)) <= ?
        ORDER BY priority DESC, topic, id LIMIT 100`,
      params: [PROMPT_CHAR_BUDGET, 6 * PROMPT_CHAR_BUDGET + 2],
    }) as unknown as Promise<
      Pick<Memory, "id" | "content" | "topic" | "priority">[]
    >,
  ]);
  const total = Number(totals[0].total);
  const header =
    "用户跨作品创作偏好（用户要求修改或遗忘时可使用方括号中的 ID）：\n";
  const groups = new Map<string, string[]>();
  let count = 0;
  let used = header.length;
  for (const row of rows) {
    const label = row.topic || "通用";
    const group = groups.get(label);
    const line = `- [${row.id}]${row.priority === 1 ? "（核心）" : ""} ${row.content}\n`;
    const cost = line.length + (group ? 0 : label.length + 4);
    if (used + cost > PROMPT_CHAR_BUDGET) {
      continue;
    }
    if (group) {
      group.push(line);
    } else {
      groups.set(label, [line]);
    }
    count++;
    used += cost;
  }
  const sortedGroups = [...groups.entries()].sort(([a], [b]) => {
    if (a === "通用") return 1;
    if (b === "通用") return -1;
    return a.localeCompare(b, "zh-CN");
  });
  const overflow = Math.max(0, total - count);
  const text = count
    ? (
        header +
        sortedGroups
          .map(([label, lines]) => `\n[${label}]\n${lines.join("")}`)
          .join("")
      ).trimEnd()
    : "";
  return {
    text,
    count,
    total,
    overflow,
    budget: PROMPT_CHAR_BUDGET,
    used: text.length,
  };
}

/**
 * 同步「创作记忆」页面入口角标：
 * 1. 有待确认梦境建议时优先显示待处理计数（accent）；
 * 2. 否则若有生效偏好超出注入预算，显示警告状态点（warning）；
 * 3. 二者都无时清除角标。
 */
export async function syncMemoryBadge(
  db: Pick<PluginSqlite, "query">,
  storage: Pick<PluginStorage, "set" | "remove">,
): Promise<PageBadge | null> {
  const [pendingRows, injection] = await Promise.all([
    db.query({
      sql: "SELECT COUNT(*) AS total FROM suggestions WHERE status = 'pending'",
    }),
    prompt(db),
  ]);
  const pendingCount = Number(pendingRows[0]?.total ?? 0);
  const badge: PageBadge | null =
    pendingCount > 0
      ? { count: pendingCount, tone: "accent" }
      : injection.overflow > 0
        ? { dot: true, tone: "warning" }
        : null;
  await setPageBadge(storage, MANAGE_PAGE_ID, badge);
  return badge;
}

export async function pendingSuggestions(
  db: Pick<PluginSqlite, "query">,
  offset = 0,
) {
  const rows = await db.query({
    sql: "SELECT * FROM suggestions WHERE status = 'pending' ORDER BY created_at DESC, id LIMIT ? OFFSET ?",
    params: [SUGGESTION_PAGE_SIZE + 1, offset],
  });
  return {
    items: await suggestionViews(db, rows.slice(0, SUGGESTION_PAGE_SIZE)),
    hasMore: rows.length > SUGGESTION_PAGE_SIZE,
  };
}

async function suggestionViews(
  db: Pick<PluginSqlite, "query">,
  rows: readonly Record<string, SqlValue>[],
): Promise<SuggestionView[]> {
  if (!rows.length) return [];
  const placeholders = rows.map(() => "?").join(", ");
  const sourcesRows = await db.query({
    sql: `SELECT ss.suggestion_id, ss.memory_id, ss.source_revision,
      m.revision AS current_revision, m.status AS current_status, m.deleted_at,
      CASE WHEN m.deleted_at IS NULL THEN substr(m.content, 1, ?) END AS content,
      length(m.content) > ? AS content_truncated, m.topic, m.priority
      FROM suggestion_sources ss LEFT JOIN memories m ON m.id = ss.memory_id
      WHERE ss.suggestion_id IN (${placeholders}) ORDER BY ss.suggestion_id, ss.memory_id`,
    params: [
      SOURCE_PREVIEW_LENGTH,
      SOURCE_PREVIEW_LENGTH,
      ...rows.map((row) => row.id),
    ],
  });
  const bySuggestion = new Map<string, SuggestionSourceView[]>();
  for (const row of sourcesRows) {
    const sid = String(row.suggestion_id);
    const listForSuggestion = bySuggestion.get(sid) ?? [];
    listForSuggestion.push({
      memory_id: String(row.memory_id),
      source_revision: Number(row.source_revision),
      current_revision:
        row.current_revision === null ? null : Number(row.current_revision),
      current_status:
        row.current_status === null ? null : String(row.current_status),
      deleted_at: row.deleted_at === null ? null : Number(row.deleted_at),
      content: row.content === null ? null : String(row.content),
      content_truncated: row.content !== null && row.content_truncated === 1,
      topic: row.topic === null ? "" : String(row.topic),
      priority: row.priority === null ? 0 : Number(row.priority),
    });
    bySuggestion.set(sid, listForSuggestion);
  }
  return rows.map((row) => {
    const sid = String(row.id);
    const sources = bySuggestion.get(sid) ?? [];
    const stale = sources.some(
      (source) =>
        source.deleted_at !== null ||
        source.current_status !== "active" ||
        source.current_revision !== source.source_revision,
    );
    return {
      id: sid,
      kind: String(row.kind) as SuggestionKind,
      reason: String(row.reason),
      proposed_content:
        row.proposed_content === null ? null : String(row.proposed_content),
      proposed_topic:
        row.proposed_topic === null ? "" : String(row.proposed_topic),
      proposed_priority:
        row.proposed_priority === null ? null : Number(row.proposed_priority),
      fingerprint: String(row.fingerprint),
      run_id: String(row.run_id),
      status: String(row.status),
      created_at: Number(row.created_at),
      updated_at: Number(row.updated_at),
      stale,
      sources,
    };
  });
}

export async function resolveSuggestion(
  db: PluginSqlite,
  suggestionId: string,
  apply: boolean,
  override?: { content?: string; topic?: string; priority?: number },
) {
  const rows = await db.query({
    sql: "SELECT * FROM suggestions WHERE id = ? AND status = 'pending'",
    params: [suggestionId],
  });
  const [suggestion] = await suggestionViews(db, rows);
  if (!suggestion) {
    fail("not_found", "Suggestion is no longer available");
  }
  const time = now();
  if (!apply) {
    const res = await db.execute({
      sql: "UPDATE suggestions SET status = 'ignored', updated_at = ? WHERE id = ? AND status = 'pending'",
      params: [time, suggestionId],
    });
    if (res.changes !== 1) {
      fail("not_found", "Suggestion is no longer available");
    }
    return { id: suggestionId, status: "ignored" };
  }
  if (suggestion.stale) {
    fail(
      "conflict",
      "Source memory changed; ignore this suggestion and review the current version",
    );
  }
  const statements: SqlStatement[] = [];
  const kind = suggestion.kind;
  const maxSourcePriority = suggestion.sources.reduce(
    (max, item) => Math.max(max, item.priority),
    0,
  );

  if (kind === "archive") {
    if (!suggestion.sources.length) {
      fail("invalid_argument", "Archive suggestion requires source memories");
    }
    for (const source of suggestion.sources) {
      statements.push({
        sql: "UPDATE memories SET status = 'archived', enabled = 0, revision = revision + 1, updated_at = ? WHERE id = ? AND revision = ? AND deleted_at IS NULL AND status = 'active'",
        params: [time, source.memory_id, source.source_revision],
      });
    }
  } else if (kind === "insight") {
    const clean = checked({
      content: override?.content ?? suggestion.proposed_content ?? "",
      topic: override?.topic ?? suggestion.proposed_topic,
      priority: override?.priority ?? suggestion.proposed_priority ?? 0,
      enabled: true,
    });
    const newId = id("m");
    statements.push({
      sql: "INSERT INTO memories (id, content, topic, priority, enabled, status, superseded_by, revision, created_at, updated_at) VALUES (?, ?, ?, ?, 1, 'active', NULL, 1, ?, ?)",
      params: [newId, clean.content, clean.topic, clean.priority, time, time],
    });
  } else if (
    (kind === "refine" || kind === "conflict") &&
    suggestion.sources.length === 1
  ) {
    const source = suggestion.sources[0];
    const clean = checked({
      content: override?.content ?? suggestion.proposed_content ?? "",
      topic: override?.topic ?? suggestion.proposed_topic ?? source.topic,
      priority:
        override?.priority ?? suggestion.proposed_priority ?? source.priority,
      enabled: true,
    });
    statements.push({
      sql: "UPDATE memories SET content = ?, topic = ?, priority = ?, revision = revision + 1, updated_at = ? WHERE id = ? AND revision = ? AND deleted_at IS NULL AND status = 'active'",
      params: [
        clean.content,
        clean.topic,
        clean.priority,
        time,
        source.memory_id,
        source.source_revision,
      ],
    });
  } else {
    // merge or multi-source conflict: create a consolidated memory and mark sources superseded
    if (!suggestion.sources.length) {
      fail("invalid_argument", "Suggestion requires source memories");
    }
    const clean = checked({
      content: override?.content ?? suggestion.proposed_content ?? "",
      topic: override?.topic ?? suggestion.proposed_topic,
      priority:
        override?.priority ?? suggestion.proposed_priority ?? maxSourcePriority,
      enabled: true,
    });
    const newId = id("m");
    statements.push({
      sql: "INSERT INTO memories (id, content, topic, priority, enabled, status, superseded_by, revision, created_at, updated_at) VALUES (?, ?, ?, ?, 1, 'active', NULL, 1, ?, ?)",
      params: [newId, clean.content, clean.topic, clean.priority, time, time],
    });
    for (const source of suggestion.sources) {
      statements.push({
        sql: "UPDATE memories SET status = 'superseded', superseded_by = ?, enabled = 0, revision = revision + 1, updated_at = ? WHERE id = ? AND revision = ? AND deleted_at IS NULL AND status = 'active'",
        params: [newId, time, source.memory_id, source.source_revision],
      });
    }
  }

  statements.push({
    sql: "UPDATE suggestions SET status = 'applied', updated_at = ? WHERE id = ? AND status = 'pending'",
    params: [time, suggestionId],
  });

  const results = await db.transaction(statements);
  if (results.some((r) => r.changes !== 1)) {
    fail(
      "conflict",
      "Source memory changed; ignore this suggestion and review the current version",
    );
  }
  return { id: suggestionId, status: "applied" };
}
