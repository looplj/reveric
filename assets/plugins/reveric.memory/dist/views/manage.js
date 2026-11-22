var __revericView = (() => {
  var __defProp = Object.defineProperty;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, { get: all[name], enumerable: true });
  };
  var __copyProps = (to, from, except, desc) => {
    if (from && typeof from === "object" || typeof from === "function") {
      for (let key of __getOwnPropNames(from))
        if (!__hasOwnProp.call(to, key) && key !== except)
          __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
    }
    return to;
  };
  var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

  // memory/src/views/manage.entry.js
  var manage_entry_exports = {};
  __export(manage_entry_exports, {
    mount: () => mount
  });

  // reveric-ui:reveric-plugin-sdk/ui
  var signal = globalThis.__revericUi.signal;
  var computed = globalThis.__revericUi.computed;
  var effect = globalThis.__revericUi.effect;
  var batch = globalThis.__revericUi.batch;
  var untracked = globalThis.__revericUi.untracked;
  var cleanup = globalThis.__revericUi.cleanup;
  var resource = globalThis.__revericUi.resource;
  var If = globalThis.__revericUi.If;
  var Each = globalThis.__revericUi.Each;
  var ErrorBoundary = globalThis.__revericUi.ErrorBoundary;
  var List = globalThis.__revericUi.List;
  var Tabs = globalThis.__revericUi.Tabs;

  // sdk/index.js
  var PluginError = class extends Error {
    constructor(code, message) {
      super(message);
      this.name = "PluginError";
      this.code = code;
    }
  };
  var PAGE_BADGE_STORAGE_PREFIX = "__system_internal_page_badge:";
  async function setPageBadge(storage, pageId, badge) {
    if (typeof pageId !== "string" || !pageId.trim()) {
      throw new PluginError("invalid_argument", "pageId is required");
    }
    const key = PAGE_BADGE_STORAGE_PREFIX + pageId.trim();
    if (!badge) {
      await storage.remove(key);
      return;
    }
    const payload = {};
    if (typeof badge.count === "number" && Number.isInteger(badge.count) && badge.count > 0) {
      payload.count = badge.count;
    }
    if (badge.dot === true) {
      payload.dot = true;
    }
    if (badge.tone === "accent" || badge.tone === "warning" || badge.tone === "danger") {
      payload.tone = badge.tone;
    }
    if (!payload.count && !payload.dot) {
      await storage.remove(key);
      return;
    }
    await storage.set(key, payload);
  }

  // memory/src/data.ts
  var memoryStatuses = ["active", "superseded", "archived"];
  var PROMPT_CHAR_BUDGET = 1e3;
  var MEMORY_PAGE_SIZE = 20;
  var SUGGESTION_PAGE_SIZE = 5;
  var MANAGE_PAGE_ID = "manage";
  var SOURCE_PREVIEW_LENGTH = 120;
  function fail(code, message) {
    throw new PluginError(code, message);
  }
  function id(prefix = "m") {
    const time = Date.now().toString(36).slice(-4);
    const rand = Math.random().toString(36).slice(2, 6);
    return `${prefix}_${time}${rand}`;
  }
  var now = () => Math.floor(Date.now() / 1e3);
  function normalizeTopic(value) {
    if (value === void 0 || value === null) return "";
    if (typeof value !== "string") {
      fail("invalid_argument", "topic must be a string");
    }
    const trimmed = value.trim();
    if (trimmed.length > 40) {
      fail("invalid_argument", "topic must be at most 40 characters");
    }
    return trimmed;
  }
  function checked(input) {
    const content = input.content;
    const topic = normalizeTopic(input.topic);
    const priority = input.priority ?? 0;
    const enabled = input.enabled ?? true;
    if (typeof content !== "string" || !content.trim() || content.trim().length > 4e3) {
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
      priority,
      enabled: enabled ? 1 : 0
    };
  }
  async function get(db, memoryId) {
    if (typeof memoryId !== "string" || !memoryId.trim()) {
      fail("invalid_argument", "id is required");
    }
    const rows = await db.query({
      sql: "SELECT * FROM memories WHERE id = ? AND deleted_at IS NULL",
      params: [memoryId.trim()]
    });
    if (!rows.length) fail("not_found", "Memory not found");
    return rows[0];
  }
  async function listTopics(db) {
    const rows = await db.query({
      sql: "SELECT DISTINCT topic FROM memories WHERE deleted_at IS NULL AND topic != '' ORDER BY topic"
    });
    return rows.map((row) => String(row.topic));
  }
  async function list(db, input = {}) {
    const query = typeof input.query === "string" ? input.query.trim() : "";
    const topic = typeof input.topic === "string" ? input.topic.trim() : "";
    const view = input.view ?? "active";
    const limit = input.limit ?? MEMORY_PAGE_SIZE;
    const offset = input.offset ?? 0;
    if (!["active", "history", "all"].includes(view) || query.length > 200 || topic.length > 40 || !Number.isInteger(limit) || limit < 1 || limit > 50 || !Number.isInteger(offset) || offset < 0) {
      fail("invalid_argument", "Invalid search filters or pagination");
    }
    const statusClause = view === "active" ? "status = 'active'" : view === "history" ? "status IN ('archived', 'superseded')" : "1 = 1";
    const terms = query ? query.split(/\s+/) : [];
    const hits = terms.map(() => "(instr(lower(topic || ' ' || content), lower(?)) > 0)").join(" + ");
    const base = `SELECT *${hits ? `, ${hits} AS hits` : ""} FROM memories
    WHERE deleted_at IS NULL AND ${statusClause} AND (? = '' OR topic = ?)`;
    const rows = await db.query({
      sql: `SELECT * FROM (${base})${hits ? " WHERE hits > 0" : ""}
      ORDER BY ${hits ? "hits DESC, " : ""}priority DESC, updated_at DESC, id
      LIMIT ? OFFSET ?`,
      params: [...terms, topic, topic, limit + 1, offset]
    });
    return {
      items: rows.slice(0, limit).map(({ hits: _hits, ...memory }) => memory),
      hasMore: rows.length > limit
    };
  }
  async function create(db, input) {
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
        time
      ]
    });
    return get(db, key);
  }
  async function update(db, input, options = {}) {
    const original = await get(db, input.id);
    const requireRevision = options.requireRevision ?? true;
    if (requireRevision) {
      if (!Number.isInteger(input.revision) || Number(input.revision) < 1) {
        fail("invalid_argument", "revision is required");
      }
    }
    const remove = options.remove ?? false;
    const nextStatus = input.status !== void 0 ? String(input.status) : original.status;
    if (!memoryStatuses.includes(nextStatus)) {
      fail("invalid_argument", "Invalid status");
    }
    const value = remove ? {
      content: original.content,
      topic: original.topic,
      priority: original.priority,
      enabled: original.enabled
    } : checked({
      content: original.content,
      topic: original.topic,
      priority: original.priority,
      enabled: original.enabled === 1,
      ...input
    });
    const nextEnabled = nextStatus === "active" ? value.enabled : 0;
    const nextSupersededBy = nextStatus === "active" ? null : original.superseded_by;
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
      ...requireRevision ? [Number(input.revision)] : []
    ];
    const result = await db.execute({
      sql: `UPDATE memories SET content = ?, topic = ?, priority = ?, enabled = ?, status = ?, superseded_by = ?, revision = revision + 1, updated_at = ?, deleted_at = ? WHERE id = ? AND deleted_at IS NULL${whereRevision}`,
      params
    });
    if (result.changes !== 1) {
      fail("conflict", "Memory changed; refresh before editing");
    }
    return remove ? { id: original.id, deleted: true } : get(db, original.id);
  }
  async function prompt(db) {
    const where = "deleted_at IS NULL AND status = 'active' AND enabled = 1";
    const [totals, rows] = await Promise.all([
      db.query({ sql: `SELECT COUNT(*) AS total FROM memories WHERE ${where}` }),
      db.query({
        // Cap the encoded bytes as well so the worst case fits the 1 MB bridge.
        sql: `SELECT id, content, topic, priority FROM memories WHERE ${where}
        AND length(content) <= ? AND length(CAST(json_quote(content) AS BLOB)) <= ?
        ORDER BY priority DESC, topic, id LIMIT 100`,
        params: [PROMPT_CHAR_BUDGET, 6 * PROMPT_CHAR_BUDGET + 2]
      })
    ]);
    const total = Number(totals[0].total);
    const header = "用户跨作品创作偏好（用户要求修改或遗忘时可使用方括号中的 ID）：\n";
    const groups = /* @__PURE__ */ new Map();
    let count = 0;
    let used = header.length;
    for (const row of rows) {
      const label = row.topic || "通用";
      const group = groups.get(label);
      const line = `- [${row.id}]${row.priority === 1 ? "（核心）" : ""} ${row.content}
`;
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
    const text = count ? (header + sortedGroups.map(([label, lines]) => `
[${label}]
${lines.join("")}`).join("")).trimEnd() : "";
    return {
      text,
      count,
      total,
      overflow,
      budget: PROMPT_CHAR_BUDGET,
      used: text.length
    };
  }
  async function syncMemoryBadge(db, storage) {
    const [pendingRows, injection] = await Promise.all([
      db.query({
        sql: "SELECT COUNT(*) AS total FROM suggestions WHERE status = 'pending'"
      }),
      prompt(db)
    ]);
    const pendingCount = Number(pendingRows[0]?.total ?? 0);
    const badge = pendingCount > 0 ? { count: pendingCount, tone: "accent" } : injection.overflow > 0 ? { dot: true, tone: "warning" } : null;
    await setPageBadge(storage, MANAGE_PAGE_ID, badge);
    return badge;
  }
  async function pendingSuggestions(db, offset = 0) {
    const rows = await db.query({
      sql: "SELECT * FROM suggestions WHERE status = 'pending' ORDER BY created_at DESC, id LIMIT ? OFFSET ?",
      params: [SUGGESTION_PAGE_SIZE + 1, offset]
    });
    return {
      items: await suggestionViews(db, rows.slice(0, SUGGESTION_PAGE_SIZE)),
      hasMore: rows.length > SUGGESTION_PAGE_SIZE
    };
  }
  async function suggestionViews(db, rows) {
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
        ...rows.map((row) => row.id)
      ]
    });
    const bySuggestion = /* @__PURE__ */ new Map();
    for (const row of sourcesRows) {
      const sid = String(row.suggestion_id);
      const listForSuggestion = bySuggestion.get(sid) ?? [];
      listForSuggestion.push({
        memory_id: String(row.memory_id),
        source_revision: Number(row.source_revision),
        current_revision: row.current_revision === null ? null : Number(row.current_revision),
        current_status: row.current_status === null ? null : String(row.current_status),
        deleted_at: row.deleted_at === null ? null : Number(row.deleted_at),
        content: row.content === null ? null : String(row.content),
        content_truncated: row.content !== null && row.content_truncated === 1,
        topic: row.topic === null ? "" : String(row.topic),
        priority: row.priority === null ? 0 : Number(row.priority)
      });
      bySuggestion.set(sid, listForSuggestion);
    }
    return rows.map((row) => {
      const sid = String(row.id);
      const sources = bySuggestion.get(sid) ?? [];
      const stale = sources.some(
        (source) => source.deleted_at !== null || source.current_status !== "active" || source.current_revision !== source.source_revision
      );
      return {
        id: sid,
        kind: String(row.kind),
        reason: String(row.reason),
        proposed_content: row.proposed_content === null ? null : String(row.proposed_content),
        proposed_topic: row.proposed_topic === null ? "" : String(row.proposed_topic),
        proposed_priority: row.proposed_priority === null ? null : Number(row.proposed_priority),
        fingerprint: String(row.fingerprint),
        run_id: String(row.run_id),
        status: String(row.status),
        created_at: Number(row.created_at),
        updated_at: Number(row.updated_at),
        stale,
        sources
      };
    });
  }
  async function resolveSuggestion(db, suggestionId, apply, override) {
    const rows = await db.query({
      sql: "SELECT * FROM suggestions WHERE id = ? AND status = 'pending'",
      params: [suggestionId]
    });
    const [suggestion] = await suggestionViews(db, rows);
    if (!suggestion) {
      fail("not_found", "Suggestion is no longer available");
    }
    const time = now();
    if (!apply) {
      const res = await db.execute({
        sql: "UPDATE suggestions SET status = 'ignored', updated_at = ? WHERE id = ? AND status = 'pending'",
        params: [time, suggestionId]
      });
      if (res.changes !== 1) {
        fail("not_found", "Suggestion is no longer available");
      }
      return { id: suggestionId, status: "ignored" };
    }
    if (suggestion.stale) {
      fail(
        "conflict",
        "Source memory changed; ignore this suggestion and review the current version"
      );
    }
    const statements = [];
    const kind = suggestion.kind;
    const maxSourcePriority = suggestion.sources.reduce(
      (max, item) => Math.max(max, item.priority),
      0
    );
    if (kind === "archive") {
      if (!suggestion.sources.length) {
        fail("invalid_argument", "Archive suggestion requires source memories");
      }
      for (const source of suggestion.sources) {
        statements.push({
          sql: "UPDATE memories SET status = 'archived', enabled = 0, revision = revision + 1, updated_at = ? WHERE id = ? AND revision = ? AND deleted_at IS NULL AND status = 'active'",
          params: [time, source.memory_id, source.source_revision]
        });
      }
    } else if (kind === "insight") {
      const clean = checked({
        content: override?.content ?? suggestion.proposed_content ?? "",
        topic: override?.topic ?? suggestion.proposed_topic,
        priority: override?.priority ?? suggestion.proposed_priority ?? 0,
        enabled: true
      });
      const newId = id("m");
      statements.push({
        sql: "INSERT INTO memories (id, content, topic, priority, enabled, status, superseded_by, revision, created_at, updated_at) VALUES (?, ?, ?, ?, 1, 'active', NULL, 1, ?, ?)",
        params: [newId, clean.content, clean.topic, clean.priority, time, time]
      });
    } else if ((kind === "refine" || kind === "conflict") && suggestion.sources.length === 1) {
      const source = suggestion.sources[0];
      const clean = checked({
        content: override?.content ?? suggestion.proposed_content ?? "",
        topic: override?.topic ?? suggestion.proposed_topic ?? source.topic,
        priority: override?.priority ?? suggestion.proposed_priority ?? source.priority,
        enabled: true
      });
      statements.push({
        sql: "UPDATE memories SET content = ?, topic = ?, priority = ?, revision = revision + 1, updated_at = ? WHERE id = ? AND revision = ? AND deleted_at IS NULL AND status = 'active'",
        params: [
          clean.content,
          clean.topic,
          clean.priority,
          time,
          source.memory_id,
          source.source_revision
        ]
      });
    } else {
      if (!suggestion.sources.length) {
        fail("invalid_argument", "Suggestion requires source memories");
      }
      const clean = checked({
        content: override?.content ?? suggestion.proposed_content ?? "",
        topic: override?.topic ?? suggestion.proposed_topic,
        priority: override?.priority ?? suggestion.proposed_priority ?? maxSourcePriority,
        enabled: true
      });
      const newId = id("m");
      statements.push({
        sql: "INSERT INTO memories (id, content, topic, priority, enabled, status, superseded_by, revision, created_at, updated_at) VALUES (?, ?, ?, ?, 1, 'active', NULL, 1, ?, ?)",
        params: [newId, clean.content, clean.topic, clean.priority, time, time]
      });
      for (const source of suggestion.sources) {
        statements.push({
          sql: "UPDATE memories SET status = 'superseded', superseded_by = ?, enabled = 0, revision = revision + 1, updated_at = ? WHERE id = ? AND revision = ? AND deleted_at IS NULL AND status = 'active'",
          params: [newId, time, source.memory_id, source.source_revision]
        });
      }
    }
    statements.push({
      sql: "UPDATE suggestions SET status = 'applied', updated_at = ? WHERE id = ? AND status = 'pending'",
      params: [time, suggestionId]
    });
    const results = await db.transaction(statements);
    if (results.some((r) => r.changes !== 1)) {
      fail(
        "conflict",
        "Source memory changed; ignore this suggestion and review the current version"
      );
    }
    return { id: suggestionId, status: "applied" };
  }

  // memory/src/views/manage.tsx
  var kindMeta = {
    conflict: { label: "冲突", tone: "warning" },
    merge: { label: "合并", tone: "accent" },
    archive: { label: "清理", tone: "muted" },
    refine: { label: "精简", tone: "accent" },
    insight: { label: "风格画像", tone: "success" }
  };
  function Page(context) {
    const view = signal("active");
    const topicFilter = signal("");
    const query = signal("");
    const offset = signal(0);
    const suggestionOffset = signal(0);
    const rows = signal([]);
    const topics = signal([]);
    const more = signal(false);
    const preview = signal("");
    const budget = signal("");
    const overflowCount = signal(0);
    const budgetUsed = signal(0);
    const budgetTotal = signal(PROMPT_CHAR_BUDGET);
    const candidates = signal([]);
    const moreSuggestions = signal(false);
    const loading = signal(false);
    const loadingSuggestions = signal(false);
    const busy = signal(false);
    const error = signal("");
    const failedReads = signal([]);
    const editing = signal(false);
    const editId = signal("");
    const editRevision = signal(0);
    const resolvingSuggestionId = signal("");
    const content = signal("");
    const editTopic = signal("");
    const priority = signal(false);
    const enabled = signal(true);
    const refresh = signal(0);
    let alive = true;
    cleanup(() => {
      alive = false;
    });
    function loadSection(name, read, show, setLoading) {
      effect(() => {
        refresh();
        if (!context.environment.visible())
          return;
        let current = true;
        cleanup(() => {
          current = false;
        });
        setLoading?.(true);
        void read().then((result) => {
          if (!current)
            return;
          failedReads.update((sections) => sections.filter((section) => section !== name));
          show(result);
        }).catch((cause) => {
          if (!current)
            return;
          context.log.warn("Memory page query failed", {
            section: name,
            error: String(cause)
          });
          failedReads.update((sections) => sections.includes(name) ? sections : [...sections, name]);
        }).finally(() => {
          if (current)
            setLoading?.(false);
        });
      });
    }
    loadSection("创作偏好", () => list(context.sqlite, {
      view: view(),
      topic: topicFilter(),
      query: query(),
      offset: offset()
    }), ({ items, hasMore }) => {
      if (!items.length && offset() > 0) {
        offset.update((value) => Math.max(0, value - MEMORY_PAGE_SIZE));
        return;
      }
      rows.set(items);
      more.set(hasMore);
    }, loading.set);
    loadSection("主题", () => listTopics(context.sqlite), (items) => {
      topics.set(items);
      if (topicFilter() && !items.includes(topicFilter())) {
        filter(() => topicFilter.set(""));
      }
    });
    loadSection("聊天参考预览", () => prompt(context.sqlite), (injection) => {
      preview.set(injection.text || (injection.total > 0 ? chinese() ? "当前偏好均超出聊天参考的字符预算" : "The current preferences exceed the chat context budget." : "当前没有生效的创作偏好"));
      budget.set(`已注入 ${injection.count}/${injection.total} 条 · 字符预算 ${injection.used}/${injection.budget}`);
      overflowCount.set(injection.overflow);
      budgetUsed.set(injection.used);
      budgetTotal.set(injection.budget);
      void syncMemoryBadge(context.sqlite, context.storage).catch((cause) => {
        context.log.warn("Memory badge sync failed", { error: String(cause) });
      });
    });
    loadSection("梦境整理建议", () => pendingSuggestions(context.sqlite, suggestionOffset()), ({ items, hasMore }) => {
      if (!items.length && suggestionOffset() > 0) {
        suggestionOffset.update((value) => Math.max(0, value - SUGGESTION_PAGE_SIZE));
        return;
      }
      candidates.set(items);
      moreSuggestions.set(hasMore);
    }, loadingSuggestions.set);
    function reload() {
      refresh.update((value) => value + 1);
    }
    function filter(change) {
      batch(() => {
        change();
        offset.set(0);
      });
    }
    async function closeEditor() {
      editing.set(false);
      resolvingSuggestionId.set("");
      await context.view.setDirty(false);
    }
    async function openEdit(row) {
      if (editing() && !await context.ui.dialog({ title: "放弃未保存的修改？" })) {
        return;
      }
      resolvingSuggestionId.set("");
      editId.set(row?.id ?? "");
      editRevision.set(row?.revision ?? 0);
      content.set(row?.content ?? "");
      editTopic.set(row?.topic ?? "");
      priority.set(row?.priority === 1);
      enabled.set(row ? row.enabled === 1 : true);
      editing.set(true);
      await context.view.setDirty(true);
    }
    async function openSuggestionEditor(suggestion) {
      if (editing() && !await context.ui.dialog({ title: "放弃未保存的修改？" })) {
        return;
      }
      resolvingSuggestionId.set(suggestion.id);
      editId.set("");
      editRevision.set(0);
      content.set(suggestion.proposed_content ?? "");
      editTopic.set(suggestion.proposed_topic || suggestion.sources[0]?.topic || "");
      priority.set(suggestion.proposed_priority === 1 || suggestion.sources.some((item) => item.priority === 1));
      enabled.set(true);
      editing.set(true);
      await context.view.setDirty(true);
    }
    async function act(action) {
      if (busy())
        return;
      busy.set(true);
      error.set("");
      try {
        await action();
        if (alive)
          reload();
      } catch (cause) {
        if (alive) {
          error.set(cause instanceof PluginError && cause.code === "conflict" ? "记录已更新，请保留当前草稿并刷新查看最新版本。" : "操作失败，请检查输入或刷新重试。");
        }
      } finally {
        if (alive)
          busy.set(false);
      }
    }
    async function save() {
      await act(async () => {
        if (resolvingSuggestionId()) {
          await resolveSuggestion(context.sqlite, resolvingSuggestionId(), true, {
            content: content(),
            topic: editTopic(),
            priority: priority() ? 1 : 0
          });
        } else if (editId()) {
          await update(context.sqlite, {
            id: editId(),
            revision: editRevision(),
            content: content(),
            topic: editTopic(),
            priority: priority() ? 1 : 0,
            enabled: enabled()
          });
        } else {
          await create(context.sqlite, {
            content: content(),
            topic: editTopic(),
            priority: priority() ? 1 : 0,
            enabled: enabled()
          });
        }
        if (alive)
          await closeEditor();
      });
    }
    async function choose(row, actionId) {
      if (actionId === "edit")
        return openEdit(row);
      if (actionId === "toggle") {
        return act(() => update(context.sqlite, {
          id: row.id,
          revision: row.revision,
          enabled: row.enabled !== 1
        }));
      }
      if (actionId === "archive") {
        return act(() => update(context.sqlite, {
          id: row.id,
          revision: row.revision,
          status: "archived",
          enabled: false
        }));
      }
      if (actionId === "restore") {
        return act(() => update(context.sqlite, {
          id: row.id,
          revision: row.revision,
          status: "active",
          enabled: true
        }));
      }
      if (actionId === "delete" && await context.ui.dialog({
        title: "删除这条创作偏好？",
        message: "删除后不再加入聊天参考。",
        confirmLabel: "删除",
        tone: "danger"
      })) {
        await act(() => update(context.sqlite, { id: row.id, revision: row.revision }, { remove: true }));
      }
    }
    const compact = () => context.environment.width() < 600;
    const wideToolbar = () => context.environment.width() >= 720;
    const chinese = () => context.environment.locale().startsWith("zh");
    const readError = () => failedReads().length ? `读取失败，请刷新重试。${failedReads().join("、")}` : "";
    async function showOriginal(id2) {
      try {
        const original = await get(context.sqlite, id2);
        if (alive) {
          await context.ui.dialog({
            title: chinese() ? "原偏好" : "Original preference",
            message: original.content
          });
        }
      } catch (cause) {
        if (!alive)
          return;
        context.log.warn("Memory source could not be opened", {
          id: id2,
          error: String(cause)
        });
        error.set(chinese() ? "读取失败，请刷新重试。" : "Could not load the preference. Refresh and try again.");
      }
    }
    function pager(pageOffset, pageSize, hasMore, pending) {
      return globalThis.__revericUi.component(If, {
        get "when"() {
          return pageOffset() > 0 || hasMore();
        },
        get children() {
          return globalThis.__revericUi.element("Row", {
            "gap": "sm",
            "align": "center",
            "justify": "center",
            get children() {
              return [globalThis.__revericUi.element("Button", {
                "label": "上一页",
                "size": "compact",
                get "disabled"() {
                  return pageOffset() === 0 || pending();
                },
                "onPress": () => pageOffset.update((value) => Math.max(0, value - pageSize))
              }), globalThis.__revericUi.element("Text", {
                get "text"() {
                  return `第 ${pageOffset() / pageSize + 1} 页`;
                },
                "tone": "muted"
              }), globalThis.__revericUi.element("Button", {
                "label": "下一页",
                "size": "compact",
                get "disabled"() {
                  return !hasMore() || pending();
                },
                "onPress": () => pageOffset.update((value) => value + pageSize)
              })];
            }
          });
        }
      });
    }
    const editorTitle = () => resolvingSuggestionId() ? "编辑后应用梦境建议" : editId() ? "编辑创作偏好" : "新建创作偏好";
    const searchField = () => globalThis.__revericUi.element("SearchField", {
      "flex": 1,
      "placeholder": "搜索创作偏好（支持多关键词）",
      get "value"() {
        return query();
      },
      "debounceMs": 300,
      "onChange": (e) => filter(() => query.set(e.value))
    });
    const filterSelects = (expand) => globalThis.__revericUi.element("Row", {
      "gap": "sm",
      "align": "center",
      get children() {
        return [globalThis.__revericUi.element("Box", {
          get "width"() {
            return expand ? void 0 : 148;
          },
          get "flex"() {
            return expand ? 1 : void 0;
          },
          get children() {
            return globalThis.__revericUi.element("Select", {
              get "value"() {
                return view();
              },
              get "options"() {
                return [
                  { value: "active", label: "生效中" },
                  { value: "history", label: "已归档与历史" }
                ];
              },
              "onChange": (e) => filter(() => view.set(e.value === "history" ? "history" : "active"))
            });
          }
        }), globalThis.__revericUi.element("Box", {
          get "width"() {
            return expand ? void 0 : 148;
          },
          get "flex"() {
            return expand ? 1 : void 0;
          },
          get children() {
            return globalThis.__revericUi.element("Select", {
              get "value"() {
                return topicFilter();
              },
              get "options"() {
                return [
                  { value: "", label: "全部主题" },
                  ...topics().map((t) => ({ value: t, label: t }))
                ];
              },
              "onChange": (e) => filter(() => topicFilter.set(e.value ?? ""))
            });
          }
        })];
      }
    });
    const refreshButton = () => globalThis.__revericUi.element("IconButton", {
      "icon": "refresh",
      "tooltip": "刷新",
      get "disabled"() {
        return loading();
      },
      get "onPress"() {
        return reload;
      }
    });
    const createButton = () => globalThis.__revericUi.element("Button", {
      "label": "新建",
      "icon": "add",
      get "disabled"() {
        return busy();
      },
      "variant": "primary",
      "onPress": () => openEdit()
    });
    return globalThis.__revericUi.element("Scroll", {
      get children() {
        return globalThis.__revericUi.element("Box", {
          get "padding"() {
            return compact() ? "lg" : "x2l";
          },
          "maxWidth": 960,
          get children() {
            return globalThis.__revericUi.element("Column", {
              "gap": "xl",
              "align": "stretch",
              get children() {
                return [globalThis.__revericUi.element("Text", {
                  "text": "这里存放跨作品的长期创作偏好，只在你明确要求记住或手动新建时写入。梦境整理只会生成待确认建议，绝不会擅自改写原偏好。",
                  "tone": "muted"
                }), globalThis.__revericUi.component(If, {
                  get "when"() {
                    return wideToolbar();
                  },
                  get "fallback"() {
                    return globalThis.__revericUi.element("Column", {
                      "gap": "sm",
                      "align": "stretch",
                      get children() {
                        return [globalThis.__revericUi.element("Row", {
                          "gap": "sm",
                          "align": "center",
                          get children() {
                            return [globalThis.__revericUi.element("Fragment", { get children() {
                              return searchField();
                            } }), globalThis.__revericUi.element("Fragment", { get children() {
                              return refreshButton();
                            } }), globalThis.__revericUi.element("Fragment", { get children() {
                              return createButton();
                            } })];
                          }
                        }), globalThis.__revericUi.element("Fragment", { get children() {
                          return filterSelects(true);
                        } })];
                      }
                    });
                  },
                  get children() {
                    return globalThis.__revericUi.element("Row", {
                      "gap": "sm",
                      "align": "center",
                      get children() {
                        return [globalThis.__revericUi.element("Fragment", { get children() {
                          return searchField();
                        } }), globalThis.__revericUi.element("Fragment", { get children() {
                          return filterSelects(false);
                        } }), globalThis.__revericUi.element("Fragment", { get children() {
                          return refreshButton();
                        } }), globalThis.__revericUi.element("Fragment", { get children() {
                          return createButton();
                        } })];
                      }
                    });
                  }
                }), globalThis.__revericUi.component(If, {
                  get "when"() {
                    return overflowCount() > 0;
                  },
                  get children() {
                    return globalThis.__revericUi.element("Card", {
                      "padding": "md",
                      get children() {
                        return globalThis.__revericUi.element("Row", {
                          "gap": "sm",
                          "align": "center",
                          get children() {
                            return [globalThis.__revericUi.element("Icon", {
                              "name": "warning",
                              "size": "small",
                              "tone": "warning"
                            }), globalThis.__revericUi.element("Text", {
                              "flex": 1,
                              "tone": "warning",
                              get "text"() {
                                return `有 ${overflowCount()} 条生效偏好超出聊天注入预算（${budgetUsed()}/${budgetTotal()} 字）未展开；可精简内容、停用或归档次要条目，或将关键条目设为「核心偏好」优先注入。`;
                              }
                            })];
                          }
                        });
                      }
                    });
                  }
                }), globalThis.__revericUi.component(If, {
                  get "when"() {
                    return error() !== "" || readError() !== "";
                  },
                  get children() {
                    return globalThis.__revericUi.element("Text", {
                      get "text"() {
                        return error() || readError();
                      },
                      "tone": "warning"
                    });
                  }
                }), globalThis.__revericUi.component(If, {
                  get "when"() {
                    return editing();
                  },
                  get children() {
                    return globalThis.__revericUi.element("Card", {
                      "padding": "lg",
                      get children() {
                        return globalThis.__revericUi.element("Column", {
                          "gap": "md",
                          "align": "stretch",
                          get children() {
                            return [globalThis.__revericUi.element("Text", {
                              get "text"() {
                                return editorTitle();
                              },
                              "variant": "heading"
                            }), globalThis.__revericUi.element("TextField", {
                              "testId": "memory-content",
                              "label": "偏好内容",
                              "multiline": true,
                              get "value"() {
                                return content();
                              },
                              get "disabled"() {
                                return busy();
                              },
                              "onChange": (e) => content.set(e.value)
                            }), globalThis.__revericUi.element("TextField", {
                              "label": "主题（可选，如：文风、对话、节奏、协作）",
                              get "value"() {
                                return editTopic();
                              },
                              get "disabled"() {
                                return busy();
                              },
                              "onChange": (e) => editTopic.set(e.value)
                            }), globalThis.__revericUi.element("Wrap", {
                              "gap": "x2l",
                              "runGap": "sm",
                              get children() {
                                return [globalThis.__revericUi.element("Switch", {
                                  "label": "核心偏好",
                                  get "value"() {
                                    return priority();
                                  },
                                  get "disabled"() {
                                    return busy();
                                  },
                                  "onChange": (e) => priority.set(e.value)
                                }), globalThis.__revericUi.component(If, {
                                  get "when"() {
                                    return !resolvingSuggestionId();
                                  },
                                  get children() {
                                    return globalThis.__revericUi.element("Switch", {
                                      "label": "加入聊天参考",
                                      get "value"() {
                                        return enabled();
                                      },
                                      get "disabled"() {
                                        return busy();
                                      },
                                      "onChange": (e) => enabled.set(e.value)
                                    });
                                  }
                                })];
                              }
                            }), globalThis.__revericUi.element("Row", {
                              "gap": "sm",
                              "justify": "end",
                              get children() {
                                return [globalThis.__revericUi.element("Button", {
                                  "label": "取消",
                                  get "disabled"() {
                                    return busy();
                                  },
                                  get "onPress"() {
                                    return closeEditor;
                                  }
                                }), globalThis.__revericUi.element("Button", {
                                  "testId": "memory-save",
                                  "label": "保存",
                                  "variant": "primary",
                                  get "loading"() {
                                    return busy();
                                  },
                                  get "onPress"() {
                                    return save;
                                  }
                                })];
                              }
                            })];
                          }
                        });
                      }
                    });
                  }
                }), globalThis.__revericUi.element("Column", {
                  "gap": "sm",
                  "align": "stretch",
                  get children() {
                    return [globalThis.__revericUi.component(If, {
                      get "when"() {
                        return !loading() && rows().length === 0;
                      },
                      get children() {
                        return globalThis.__revericUi.element("EmptyState", {
                          "message": "没有匹配的创作偏好"
                        });
                      }
                    }), globalThis.__revericUi.component(Each, {
                      get "items"() {
                        return rows();
                      },
                      get "key"() {
                        return (row) => row.id;
                      },
                      get children() {
                        return (row) => globalThis.__revericUi.element("Card", {
                          "padding": "lg",
                          get children() {
                            return globalThis.__revericUi.element("Column", {
                              "gap": "sm",
                              "align": "stretch",
                              get children() {
                                return [globalThis.__revericUi.element("Row", {
                                  "gap": "xs",
                                  "align": "center",
                                  get children() {
                                    return [globalThis.__revericUi.component(If, {
                                      get "when"() {
                                        return row().topic !== "";
                                      },
                                      get children() {
                                        return globalThis.__revericUi.element("Badge", {
                                          get "text"() {
                                            return row().topic;
                                          },
                                          "tone": "accent"
                                        });
                                      }
                                    }), globalThis.__revericUi.component(If, {
                                      get "when"() {
                                        return row().priority === 1;
                                      },
                                      get children() {
                                        return globalThis.__revericUi.element("Badge", {
                                          "text": "核心",
                                          "tone": "success"
                                        });
                                      }
                                    }), globalThis.__revericUi.component(If, {
                                      get "when"() {
                                        return row().status === "superseded";
                                      },
                                      get children() {
                                        return globalThis.__revericUi.element("Badge", {
                                          "text": "已合并",
                                          "tone": "muted"
                                        });
                                      }
                                    }), globalThis.__revericUi.component(If, {
                                      get "when"() {
                                        return row().status === "archived";
                                      },
                                      get children() {
                                        return globalThis.__revericUi.element("Badge", {
                                          "text": "已归档",
                                          "tone": "muted"
                                        });
                                      }
                                    }), globalThis.__revericUi.component(If, {
                                      get "when"() {
                                        return row().status === "active" && row().enabled !== 1;
                                      },
                                      get children() {
                                        return globalThis.__revericUi.element("Badge", {
                                          "text": "已停用",
                                          "tone": "warning"
                                        });
                                      }
                                    }), globalThis.__revericUi.element("Gap", {
                                      "flex": 1,
                                      "size": "none"
                                    }), globalThis.__revericUi.element("Text", {
                                      get "text"() {
                                        return `${row().id} · v${row().revision}`;
                                      },
                                      "variant": "caption",
                                      "tone": "muted"
                                    }), globalThis.__revericUi.element("Menu", {
                                      get "items"() {
                                        return row().status === "active" ? [
                                          { id: "edit", label: "编辑", disabled: busy() },
                                          {
                                            id: "toggle",
                                            label: row().enabled ? "停用" : "启用",
                                            disabled: busy()
                                          },
                                          {
                                            id: "archive",
                                            label: "归档",
                                            disabled: busy()
                                          },
                                          {
                                            id: "delete",
                                            label: "删除",
                                            danger: true,
                                            disabled: busy()
                                          }
                                        ] : [
                                          {
                                            id: "restore",
                                            label: "恢复为生效中",
                                            disabled: busy()
                                          },
                                          {
                                            id: "delete",
                                            label: "删除",
                                            danger: true,
                                            disabled: busy()
                                          }
                                        ];
                                      },
                                      "onSelect": (e) => choose(row(), e.id),
                                      get "trigger"() {
                                        return globalThis.__revericUi.element("IconButton", {
                                          "icon": "moreHoriz",
                                          "tooltip": "更多操作"
                                        });
                                      }
                                    })];
                                  }
                                }), globalThis.__revericUi.element("Text", {
                                  get "text"() {
                                    return row().content;
                                  },
                                  get "tone"() {
                                    return row().status === "active" && row().enabled === 1 ? "default" : "muted";
                                  }
                                }), globalThis.__revericUi.component(If, {
                                  get "when"() {
                                    return row().superseded_by !== null;
                                  },
                                  get children() {
                                    return globalThis.__revericUi.element("Text", {
                                      get "text"() {
                                        return `已合并至 ${row().superseded_by}`;
                                      },
                                      "variant": "caption",
                                      "tone": "muted"
                                    });
                                  }
                                })];
                              }
                            });
                          }
                        });
                      }
                    }), globalThis.__revericUi.element("Fragment", { get children() {
                      return pager(offset, MEMORY_PAGE_SIZE, more, loading);
                    } })];
                  }
                }), globalThis.__revericUi.element("Column", {
                  "gap": "sm",
                  "align": "stretch",
                  get children() {
                    return [globalThis.__revericUi.element("Text", {
                      "text": "梦境整理建议",
                      "variant": "heading"
                    }), globalThis.__revericUi.component(If, {
                      get "when"() {
                        return !loadingSuggestions() && candidates().length === 0;
                      },
                      get children() {
                        return globalThis.__revericUi.element("Text", {
                          "text": "暂无待确认的梦境建议",
                          "tone": "muted"
                        });
                      }
                    }), globalThis.__revericUi.component(Each, {
                      get "items"() {
                        return candidates();
                      },
                      get "key"() {
                        return (item) => item.id;
                      },
                      get children() {
                        return (item) => globalThis.__revericUi.element("Card", {
                          "padding": "lg",
                          get children() {
                            return globalThis.__revericUi.element("Column", {
                              "gap": "sm",
                              "align": "stretch",
                              get children() {
                                return [globalThis.__revericUi.element("Row", {
                                  "gap": "xs",
                                  "align": "center",
                                  get children() {
                                    return [globalThis.__revericUi.element("Badge", {
                                      get "text"() {
                                        return kindMeta[item().kind].label;
                                      },
                                      get "tone"() {
                                        return kindMeta[item().kind].tone;
                                      }
                                    }), globalThis.__revericUi.component(If, {
                                      get "when"() {
                                        return item().proposed_topic !== "";
                                      },
                                      get children() {
                                        return globalThis.__revericUi.element("Badge", {
                                          get "text"() {
                                            return `主题：${item().proposed_topic}`;
                                          },
                                          "tone": "muted"
                                        });
                                      }
                                    })];
                                  }
                                }), globalThis.__revericUi.element("Text", {
                                  get "text"() {
                                    return `理由：${item().reason}`;
                                  },
                                  "tone": "muted"
                                }), globalThis.__revericUi.component(Each, {
                                  get "items"() {
                                    return item().sources;
                                  },
                                  get "key"() {
                                    return (s) => s.memory_id;
                                  },
                                  get children() {
                                    return (src) => globalThis.__revericUi.element("Column", {
                                      "gap": "xs",
                                      "align": "start",
                                      get children() {
                                        return [globalThis.__revericUi.element("Text", {
                                          get "text"() {
                                            return `原偏好 [${src().memory_id}]：${src().content ?? "（已删除）"}${src().content_truncated ? "…" : ""}`;
                                          },
                                          "variant": "caption",
                                          "tone": "muted"
                                        }), globalThis.__revericUi.component(If, {
                                          get "when"() {
                                            return src().content_truncated;
                                          },
                                          get children() {
                                            return globalThis.__revericUi.element("Button", {
                                              get "label"() {
                                                return chinese() ? "查看原文" : "View original";
                                              },
                                              "size": "compact",
                                              "variant": "text",
                                              "onPress": () => showOriginal(src().memory_id)
                                            });
                                          }
                                        })];
                                      }
                                    });
                                  }
                                }), globalThis.__revericUi.component(If, {
                                  get "when"() {
                                    return item().proposed_content !== null;
                                  },
                                  get children() {
                                    return globalThis.__revericUi.element("Text", {
                                      get "text"() {
                                        return `建议：${item().proposed_content}`;
                                      }
                                    });
                                  }
                                }), globalThis.__revericUi.component(If, {
                                  get "when"() {
                                    return item().kind === "archive";
                                  },
                                  get children() {
                                    return globalThis.__revericUi.element("Text", {
                                      "text": "建议操作：归档并停用以上偏好"
                                    });
                                  }
                                }), globalThis.__revericUi.component(If, {
                                  get "when"() {
                                    return item().stale;
                                  },
                                  get children() {
                                    return globalThis.__revericUi.element("Text", {
                                      "text": "关联的原偏好已更新，此建议已过期。",
                                      "tone": "warning"
                                    });
                                  }
                                }), globalThis.__revericUi.element("Row", {
                                  "gap": "sm",
                                  "justify": "end",
                                  get children() {
                                    return [globalThis.__revericUi.element("Button", {
                                      "label": "忽略",
                                      "variant": "text",
                                      get "disabled"() {
                                        return busy();
                                      },
                                      "onPress": () => act(() => resolveSuggestion(context.sqlite, item().id, false))
                                    }), globalThis.__revericUi.component(If, {
                                      get "when"() {
                                        return item().kind !== "archive";
                                      },
                                      get children() {
                                        return globalThis.__revericUi.element("Button", {
                                          "label": "编辑后应用",
                                          get "disabled"() {
                                            return busy() || item().stale;
                                          },
                                          "onPress": () => openSuggestionEditor(item())
                                        });
                                      }
                                    }), globalThis.__revericUi.element("Button", {
                                      "label": "应用",
                                      "variant": "primary",
                                      get "disabled"() {
                                        return busy() || item().stale;
                                      },
                                      "onPress": () => act(() => resolveSuggestion(context.sqlite, item().id, true))
                                    })];
                                  }
                                })];
                              }
                            });
                          }
                        });
                      }
                    }), globalThis.__revericUi.element("Fragment", { get children() {
                      return pager(suggestionOffset, SUGGESTION_PAGE_SIZE, moreSuggestions, loadingSuggestions);
                    } })];
                  }
                }), globalThis.__revericUi.element("Card", {
                  "padding": "lg",
                  get children() {
                    return globalThis.__revericUi.element("Column", {
                      "gap": "sm",
                      "align": "stretch",
                      get children() {
                        return [globalThis.__revericUi.element("Text", {
                          "text": "聊天参考预览",
                          "variant": "heading"
                        }), globalThis.__revericUi.element("Text", {
                          get "text"() {
                            return budget();
                          },
                          "variant": "caption",
                          "tone": "muted"
                        }), globalThis.__revericUi.element("Text", {
                          get "text"() {
                            return preview();
                          }
                        })];
                      }
                    });
                  }
                })];
              }
            });
          }
        });
      }
    });
  }

  // memory/src/views/manage.entry.js
  function mount(context) {
    return globalThis.__revericUi.mount(() => Page(context), context.root);
  }
  return __toCommonJS(manage_entry_exports);
})();
//# sourceMappingURL=manage.js.map
