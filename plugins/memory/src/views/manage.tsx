import {
  Badge,
  Box,
  Button,
  Card,
  Column,
  Each,
  EmptyState,
  Gap,
  Icon,
  IconButton,
  If,
  Menu,
  Row,
  Scroll,
  SearchField,
  Select,
  Switch,
  Text,
  TextField,
  Wrap,
  batch,
  cleanup,
  effect,
  signal,
  type PageContext,
} from "reveric-plugin-sdk/ui";
import { PluginError } from "reveric-plugin-sdk";
import {
  MEMORY_PAGE_SIZE,
  PROMPT_CHAR_BUDGET,
  SUGGESTION_PAGE_SIZE,
  create,
  get,
  list,
  listTopics,
  pendingSuggestions,
  prompt,
  resolveSuggestion,
  syncMemoryBadge,
  update,
  type Memory,
  type SuggestionKind,
  type SuggestionView,
} from "../data";

const kindMeta: Record<
  SuggestionKind,
  { label: string; tone: "accent" | "warning" | "success" | "muted" }
> = {
  conflict: { label: "冲突", tone: "warning" },
  merge: { label: "合并", tone: "accent" },
  archive: { label: "清理", tone: "muted" },
  refine: { label: "精简", tone: "accent" },
  insight: { label: "风格画像", tone: "success" },
};

export default function Page(context: PageContext) {
  const view = signal<"active" | "history">("active");
  const topicFilter = signal("");
  const query = signal("");
  const offset = signal(0);
  const suggestionOffset = signal(0);

  const rows = signal<Memory[]>([]);
  const topics = signal<string[]>([]);
  const more = signal(false);
  const preview = signal("");
  const budget = signal("");
  const overflowCount = signal(0);
  const budgetUsed = signal(0);
  const budgetTotal = signal(PROMPT_CHAR_BUDGET);
  const candidates = signal<SuggestionView[]>([]);
  const moreSuggestions = signal(false);

  const loading = signal(false);
  const loadingSuggestions = signal(false);
  const busy = signal(false);
  const error = signal("");
  const failedReads = signal<string[]>([]);

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

  function loadSection<T>(
    name: string,
    read: () => Promise<T>,
    show: (result: T) => void,
    setLoading?: (value: boolean) => void,
  ) {
    effect(() => {
      refresh();
      if (!context.environment.visible()) return;
      let current = true;
      cleanup(() => {
        current = false;
      });
      setLoading?.(true);
      void read()
        .then((result) => {
          if (!current) return;
          failedReads.update((sections) =>
            sections.filter((section) => section !== name),
          );
          show(result);
        })
        .catch((cause) => {
          if (!current) return;
          context.log.warn("Memory page query failed", {
            section: name,
            error: String(cause),
          });
          failedReads.update((sections) =>
            sections.includes(name) ? sections : [...sections, name],
          );
        })
        .finally(() => {
          if (current) setLoading?.(false);
        });
    });
  }

  loadSection(
    "创作偏好",
    () =>
      list(context.sqlite, {
        view: view(),
        topic: topicFilter(),
        query: query(),
        offset: offset(),
      }),
    ({ items, hasMore }) => {
      if (!items.length && offset() > 0) {
        offset.update((value) => Math.max(0, value - MEMORY_PAGE_SIZE));
        return;
      }
      rows.set(items);
      more.set(hasMore);
    },
    loading.set,
  );
  loadSection(
    "主题",
    () => listTopics(context.sqlite),
    (items) => {
      topics.set(items);
      if (topicFilter() && !items.includes(topicFilter())) {
        filter(() => topicFilter.set(""));
      }
    },
  );
  loadSection(
    "聊天参考预览",
    () => prompt(context.sqlite),
    (injection) => {
      preview.set(
        injection.text ||
          (injection.total > 0
            ? chinese()
              ? "当前偏好均超出聊天参考的字符预算"
              : "The current preferences exceed the chat context budget."
            : "当前没有生效的创作偏好"),
      );
      budget.set(
        `已注入 ${injection.count}/${injection.total} 条 · 字符预算 ${injection.used}/${injection.budget}`,
      );
      overflowCount.set(injection.overflow);
      budgetUsed.set(injection.used);
      budgetTotal.set(injection.budget);
      void syncMemoryBadge(context.sqlite, context.storage).catch((cause) => {
        context.log.warn("Memory badge sync failed", { error: String(cause) });
      });
    },
  );
  loadSection(
    "梦境整理建议",
    () => pendingSuggestions(context.sqlite, suggestionOffset()),
    ({ items, hasMore }) => {
      if (!items.length && suggestionOffset() > 0) {
        suggestionOffset.update((value) =>
          Math.max(0, value - SUGGESTION_PAGE_SIZE),
        );
        return;
      }
      candidates.set(items);
      moreSuggestions.set(hasMore);
    },
    loadingSuggestions.set,
  );

  function reload() {
    refresh.update((value) => value + 1);
  }

  function filter(change: () => void) {
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

  async function openEdit(row?: Memory) {
    if (
      editing() &&
      !(await context.ui.dialog({ title: "放弃未保存的修改？" }))
    ) {
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

  async function openSuggestionEditor(suggestion: SuggestionView) {
    if (
      editing() &&
      !(await context.ui.dialog({ title: "放弃未保存的修改？" }))
    ) {
      return;
    }
    resolvingSuggestionId.set(suggestion.id);
    editId.set("");
    editRevision.set(0);
    content.set(suggestion.proposed_content ?? "");
    editTopic.set(
      suggestion.proposed_topic || suggestion.sources[0]?.topic || "",
    );
    priority.set(
      suggestion.proposed_priority === 1 ||
        suggestion.sources.some((item) => item.priority === 1),
    );
    enabled.set(true);
    editing.set(true);
    await context.view.setDirty(true);
  }

  async function act(action: () => Promise<unknown>) {
    if (busy()) return;
    busy.set(true);
    error.set("");
    try {
      await action();
      if (alive) reload();
    } catch (cause) {
      if (alive) {
        error.set(
          cause instanceof PluginError && cause.code === "conflict"
            ? "记录已更新，请保留当前草稿并刷新查看最新版本。"
            : "操作失败，请检查输入或刷新重试。",
        );
      }
    } finally {
      if (alive) busy.set(false);
    }
  }

  async function save() {
    await act(async () => {
      if (resolvingSuggestionId()) {
        await resolveSuggestion(context.sqlite, resolvingSuggestionId(), true, {
          content: content(),
          topic: editTopic(),
          priority: priority() ? 1 : 0,
        });
      } else if (editId()) {
        await update(context.sqlite, {
          id: editId(),
          revision: editRevision(),
          content: content(),
          topic: editTopic(),
          priority: priority() ? 1 : 0,
          enabled: enabled(),
        });
      } else {
        await create(context.sqlite, {
          content: content(),
          topic: editTopic(),
          priority: priority() ? 1 : 0,
          enabled: enabled(),
        });
      }
      if (alive) await closeEditor();
    });
  }

  async function choose(row: Memory, actionId: string) {
    if (actionId === "edit") return openEdit(row);
    if (actionId === "toggle") {
      return act(() =>
        update(context.sqlite, {
          id: row.id,
          revision: row.revision,
          enabled: row.enabled !== 1,
        }),
      );
    }
    if (actionId === "archive") {
      return act(() =>
        update(context.sqlite, {
          id: row.id,
          revision: row.revision,
          status: "archived",
          enabled: false,
        }),
      );
    }
    if (actionId === "restore") {
      return act(() =>
        update(context.sqlite, {
          id: row.id,
          revision: row.revision,
          status: "active",
          enabled: true,
        }),
      );
    }
    if (
      actionId === "delete" &&
      (await context.ui.dialog({
        title: "删除这条创作偏好？",
        message: "删除后不再加入聊天参考。",
        confirmLabel: "删除",
        tone: "danger",
      }))
    ) {
      await act(() =>
        update(
          context.sqlite,
          { id: row.id, revision: row.revision },
          { remove: true },
        ),
      );
    }
  }

  const compact = () => context.environment.width() < 600;
  const wideToolbar = () => context.environment.width() >= 720;
  const chinese = () => context.environment.locale().startsWith("zh");
  const readError = () =>
    failedReads().length
      ? `读取失败，请刷新重试。${failedReads().join("、")}`
      : "";

  async function showOriginal(id: string) {
    try {
      const original = await get(context.sqlite, id);
      if (alive) {
        await context.ui.dialog({
          title: chinese() ? "原偏好" : "Original preference",
          message: original.content,
        });
      }
    } catch (cause) {
      if (!alive) return;
      context.log.warn("Memory source could not be opened", {
        id,
        error: String(cause),
      });
      error.set(
        chinese()
          ? "读取失败，请刷新重试。"
          : "Could not load the preference. Refresh and try again.",
      );
    }
  }

  function pager(
    pageOffset: typeof offset,
    pageSize: number,
    hasMore: typeof more,
    pending: typeof loading,
  ) {
    return (
      <If when={pageOffset() > 0 || hasMore()}>
        <Row gap="sm" align="center" justify="center">
          <Button
            label="上一页"
            size="compact"
            disabled={pageOffset() === 0 || pending()}
            onPress={() =>
              pageOffset.update((value) => Math.max(0, value - pageSize))
            }
          />
          <Text text={`第 ${pageOffset() / pageSize + 1} 页`} tone="muted" />
          <Button
            label="下一页"
            size="compact"
            disabled={!hasMore() || pending()}
            onPress={() => pageOffset.update((value) => value + pageSize)}
          />
        </Row>
      </If>
    );
  }
  const editorTitle = () =>
    resolvingSuggestionId()
      ? "编辑后应用梦境建议"
      : editId()
        ? "编辑创作偏好"
        : "新建创作偏好";

  const searchField = () => (
    <SearchField
      flex={1}
      placeholder="搜索创作偏好（支持多关键词）"
      value={query()}
      debounceMs={300}
      onChange={(e) => filter(() => query.set(e.value))}
    />
  );

  const filterSelects = (expand: boolean) => (
    <Row gap="sm" align="center">
      <Box width={expand ? undefined : 148} flex={expand ? 1 : undefined}>
        <Select
          value={view()}
          options={[
            { value: "active", label: "生效中" },
            { value: "history", label: "已归档与历史" },
          ]}
          onChange={(e) =>
            filter(() => view.set(e.value === "history" ? "history" : "active"))
          }
        />
      </Box>
      <Box width={expand ? undefined : 148} flex={expand ? 1 : undefined}>
        <Select
          value={topicFilter()}
          options={[
            { value: "", label: "全部主题" },
            ...topics().map((t) => ({ value: t, label: t })),
          ]}
          onChange={(e) => filter(() => topicFilter.set(e.value ?? ""))}
        />
      </Box>
    </Row>
  );

  const refreshButton = () => (
    <IconButton
      icon="refresh"
      tooltip="刷新"
      disabled={loading()}
      onPress={reload}
    />
  );

  const createButton = () => (
    <Button
      label="新建"
      icon="add"
      disabled={busy()}
      variant="primary"
      onPress={() => openEdit()}
    />
  );

  return (
    <Scroll>
      <Box padding={compact() ? "lg" : "x2l"} maxWidth={960}>
        <Column gap="xl" align="stretch">
          <Text
            text="这里存放跨作品的长期创作偏好，只在你明确要求记住或手动新建时写入。梦境整理只会生成待确认建议，绝不会擅自改写原偏好。"
            tone="muted"
          />
          <If
            when={wideToolbar()}
            fallback={
              <Column gap="sm" align="stretch">
                <Row gap="sm" align="center">
                  {searchField()}
                  {refreshButton()}
                  {createButton()}
                </Row>
                {filterSelects(true)}
              </Column>
            }
          >
            <Row gap="sm" align="center">
              {searchField()}
              {filterSelects(false)}
              {refreshButton()}
              {createButton()}
            </Row>
          </If>

          <If when={overflowCount() > 0}>
            <Card padding="md">
              <Row gap="sm" align="center">
                <Icon name="warning" size="small" tone="warning" />
                <Text
                  flex={1}
                  tone="warning"
                  text={`有 ${overflowCount()} 条生效偏好超出聊天注入预算（${budgetUsed()}/${budgetTotal()} 字）未展开；可精简内容、停用或归档次要条目，或将关键条目设为「核心偏好」优先注入。`}
                />
              </Row>
            </Card>
          </If>

          <If when={error() !== "" || readError() !== ""}>
            <Text text={error() || readError()} tone="warning" />
          </If>

          <If when={editing()}>
            <Card padding="lg">
              <Column gap="md" align="stretch">
                <Text text={editorTitle()} variant="heading" />
                <TextField
                  testId="memory-content"
                  label="偏好内容"
                  multiline
                  value={content()}
                  disabled={busy()}
                  onChange={(e) => content.set(e.value)}
                />
                <TextField
                  label="主题（可选，如：文风、对话、节奏、协作）"
                  value={editTopic()}
                  disabled={busy()}
                  onChange={(e) => editTopic.set(e.value)}
                />
                <Wrap gap="x2l" runGap="sm">
                  <Switch
                    label="核心偏好"
                    value={priority()}
                    disabled={busy()}
                    onChange={(e) => priority.set(e.value)}
                  />
                  <If when={!resolvingSuggestionId()}>
                    <Switch
                      label="加入聊天参考"
                      value={enabled()}
                      disabled={busy()}
                      onChange={(e) => enabled.set(e.value)}
                    />
                  </If>
                </Wrap>
                <Row gap="sm" justify="end">
                  <Button
                    label="取消"
                    disabled={busy()}
                    onPress={closeEditor}
                  />
                  <Button
                    testId="memory-save"
                    label="保存"
                    variant="primary"
                    loading={busy()}
                    onPress={save}
                  />
                </Row>
              </Column>
            </Card>
          </If>

          <Column gap="sm" align="stretch">
            <If when={!loading() && rows().length === 0}>
              <EmptyState message="没有匹配的创作偏好" />
            </If>
            <Each items={rows()} key={(row) => row.id}>
              {(row) => (
                <Card padding="lg">
                  <Column gap="sm" align="stretch">
                    <Row gap="xs" align="center">
                      <If when={row().topic !== ""}>
                        <Badge text={row().topic} tone="accent" />
                      </If>
                      <If when={row().priority === 1}>
                        <Badge text="核心" tone="success" />
                      </If>
                      <If when={row().status === "superseded"}>
                        <Badge text="已合并" tone="muted" />
                      </If>
                      <If when={row().status === "archived"}>
                        <Badge text="已归档" tone="muted" />
                      </If>
                      <If
                        when={row().status === "active" && row().enabled !== 1}
                      >
                        <Badge text="已停用" tone="warning" />
                      </If>
                      <Gap flex={1} size="none" />
                      <Text
                        text={`${row().id} · v${row().revision}`}
                        variant="caption"
                        tone="muted"
                      />
                      <Menu
                        items={
                          row().status === "active"
                            ? [
                                { id: "edit", label: "编辑", disabled: busy() },
                                {
                                  id: "toggle",
                                  label: row().enabled ? "停用" : "启用",
                                  disabled: busy(),
                                },
                                {
                                  id: "archive",
                                  label: "归档",
                                  disabled: busy(),
                                },
                                {
                                  id: "delete",
                                  label: "删除",
                                  danger: true,
                                  disabled: busy(),
                                },
                              ]
                            : [
                                {
                                  id: "restore",
                                  label: "恢复为生效中",
                                  disabled: busy(),
                                },
                                {
                                  id: "delete",
                                  label: "删除",
                                  danger: true,
                                  disabled: busy(),
                                },
                              ]
                        }
                        onSelect={(e) => choose(row(), e.id)}
                        trigger={
                          <IconButton icon="moreHoriz" tooltip="更多操作" />
                        }
                      />
                    </Row>
                    <Text
                      text={row().content}
                      tone={
                        row().status === "active" && row().enabled === 1
                          ? "default"
                          : "muted"
                      }
                    />
                    <If when={row().superseded_by !== null}>
                      <Text
                        text={`已合并至 ${row().superseded_by}`}
                        variant="caption"
                        tone="muted"
                      />
                    </If>
                  </Column>
                </Card>
              )}
            </Each>
            {pager(offset, MEMORY_PAGE_SIZE, more, loading)}
          </Column>

          <Column gap="sm" align="stretch">
            <Text text="梦境整理建议" variant="heading" />
            <If when={!loadingSuggestions() && candidates().length === 0}>
              <Text text="暂无待确认的梦境建议" tone="muted" />
            </If>
            <Each items={candidates()} key={(item) => item.id}>
              {(item) => (
                <Card padding="lg">
                  <Column gap="sm" align="stretch">
                    <Row gap="xs" align="center">
                      <Badge
                        text={kindMeta[item().kind].label}
                        tone={kindMeta[item().kind].tone}
                      />
                      <If when={item().proposed_topic !== ""}>
                        <Badge
                          text={`主题：${item().proposed_topic}`}
                          tone="muted"
                        />
                      </If>
                    </Row>
                    <Text text={`理由：${item().reason}`} tone="muted" />
                    <Each items={item().sources} key={(s) => s.memory_id}>
                      {(src) => (
                        <Column gap="xs" align="start">
                          <Text
                            text={`原偏好 [${src().memory_id}]：${src().content ?? "（已删除）"}${src().content_truncated ? "…" : ""}`}
                            variant="caption"
                            tone="muted"
                          />
                          <If when={src().content_truncated}>
                            <Button
                              label={chinese() ? "查看原文" : "View original"}
                              size="compact"
                              variant="text"
                              onPress={() => showOriginal(src().memory_id)}
                            />
                          </If>
                        </Column>
                      )}
                    </Each>
                    <If when={item().proposed_content !== null}>
                      <Text text={`建议：${item().proposed_content}`} />
                    </If>
                    <If when={item().kind === "archive"}>
                      <Text text="建议操作：归档并停用以上偏好" />
                    </If>
                    <If when={item().stale}>
                      <Text
                        text="关联的原偏好已更新，此建议已过期。"
                        tone="warning"
                      />
                    </If>
                    <Row gap="sm" justify="end">
                      <Button
                        label="忽略"
                        variant="text"
                        disabled={busy()}
                        onPress={() =>
                          act(() =>
                            resolveSuggestion(context.sqlite, item().id, false),
                          )
                        }
                      />
                      <If when={item().kind !== "archive"}>
                        <Button
                          label="编辑后应用"
                          disabled={busy() || item().stale}
                          onPress={() => openSuggestionEditor(item())}
                        />
                      </If>
                      <Button
                        label="应用"
                        variant="primary"
                        disabled={busy() || item().stale}
                        onPress={() =>
                          act(() =>
                            resolveSuggestion(context.sqlite, item().id, true),
                          )
                        }
                      />
                    </Row>
                  </Column>
                </Card>
              )}
            </Each>
            {pager(
              suggestionOffset,
              SUGGESTION_PAGE_SIZE,
              moreSuggestions,
              loadingSuggestions,
            )}
          </Column>

          <Card padding="lg">
            <Column gap="sm" align="stretch">
              <Text text="聊天参考预览" variant="heading" />
              <Text text={budget()} variant="caption" tone="muted" />
              <Text text={preview()} />
            </Column>
          </Card>
        </Column>
      </Box>
    </Scroll>
  );
}
