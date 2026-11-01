import {
  Badge,
  Box,
  Button,
  Card,
  Column,
  Each,
  EmptyState,
  Gap,
  If,
  IconButton,
  Menu,
  Row,
  Scroll,
  Text,
  TextField,
  SearchField,
  Select,
  Switch,
  Wrap,
  signal,
  effect,
  cleanup,
  type PageContext,
} from "reveric-plugin-sdk/ui";
import {
  categories,
  create,
  update,
  search,
  prompt,
  suggestions,
  resolveSuggestion,
  type Memory,
} from "../data";
import { PluginError, type SqlValue } from "reveric-plugin-sdk";
const labels = { fact: "事实", preference: "偏好", instruction: "持续要求" };
const options = categories.map((value) => ({ value, label: labels[value] }));
export default function Page(context: PageContext) {
  const scope = signal(context.page.workId ? "current" : "global"),
    category = signal(""),
    query = signal(""),
    offset = signal(0);
  const rows = signal<Memory[]>([]),
    more = signal(false),
    preview = signal(""),
    budget = signal(""),
    candidates = signal<Record<string, SqlValue>[]>([]);
  const loading = signal(false),
    busy = signal(false),
    error = signal(""),
    revision = signal(0),
    editing = signal(false),
    editId = signal("");
  const content = signal(""),
    editCategory = signal("fact"),
    editScope = signal("current"),
    priority = signal(false),
    enabled = signal(true);
  const refresh = signal(0);
  let sequence = 0;
  let alive = true;
  cleanup(() => {
    alive = false;
    sequence++;
  });
  effect(() => {
    const currentScope = scope(),
      currentCategory = category(),
      currentQuery = query(),
      page = offset();
    refresh();
    if (!context.environment.visible()) return;
    const token = ++sequence;
    loading.set(true);
    Promise.all([
      search(context.sqlite, context.page.workId, {
        scope: currentScope,
        category: currentCategory,
        query: currentQuery,
        offset: page,
      }),
      prompt(context.sqlite, context.page.workId),
      suggestions(context.sqlite, context.page.workId),
    ])
      .then(([result, injection, pending]) => {
        if (!alive || token !== sequence) return;
        rows.set(result.items);
        more.set(result.hasMore);
        preview.set(injection.text || "当前没有可注入的记忆");
        budget.set(
          `完整条目 ${injection.count} 条 · 保守字符预算 ${injection.used}/${injection.budget}`,
        );
        candidates.set(
          pending.filter(
            (row) =>
              currentScope === "all" ||
              (currentScope === "global"
                ? row.work_id === null
                : row.work_id === context.page.workId),
          ),
        );
      })
      .catch(() => {
        if (alive && token === sequence) error.set("读取失败，请刷新重试。");
      })
      .finally(() => {
        if (alive && token === sequence) loading.set(false);
      });
  });
  function reload() {
    refresh.update((value) => value + 1);
  }
  function filter(change: () => void) {
    change();
    offset.set(0);
  }
  async function close() {
    editing.set(false);
    await context.view.setDirty(false);
  }
  async function edit(row?: Memory) {
    if (
      editing() &&
      !(await context.ui.dialog({ title: "放弃未保存的修改？" }))
    )
      return;
    editId.set(row?.id ?? "");
    revision.set(row?.revision ?? 0);
    content.set(row?.content ?? "");
    editCategory.set(row?.category ?? "fact");
    editScope.set(
      row
        ? row.work_id === null
          ? "global"
          : "current"
        : context.page.workId
          ? "current"
          : "global",
    );
    priority.set(row?.priority === 1);
    enabled.set(row ? row.enabled === 1 : true);
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
      if (alive)
        error.set(
          cause instanceof PluginError && cause.code === "conflict"
            ? "记录已更新，请保留当前草稿并重新查看最新版本。"
            : "操作失败，请检查输入或刷新重试。",
        );
    } finally {
      if (alive) busy.set(false);
    }
  }
  async function save() {
    await act(async () => {
      const value = {
        scope: editScope(),
        content: content(),
        category: editCategory(),
        priority: priority() ? 1 : 0,
        enabled: enabled(),
      };
      if (editId())
        await update(context.sqlite, context.page.workId, {
          ...value,
          id: editId(),
          revision: revision(),
        });
      else await create(context.sqlite, context.page.workId, value);
      if (alive) await close();
    });
  }
  const rowScope = (row: Memory) =>
    row.work_id === null ? "global" : "current";
  async function choose(row: Memory, id: string) {
    if (id === "edit") return edit(row);
    if (id === "toggle")
      return act(() =>
        update(context.sqlite, context.page.workId, {
          id: row.id,
          revision: row.revision,
          scope: rowScope(row),
          enabled: !row.enabled,
        }),
      );
    if (
      id === "delete" &&
      (await context.ui.dialog({
        title: "删除这条记忆？",
        message: "删除后不再加入聊天参考。",
        confirmLabel: "删除",
        tone: "danger",
      }))
    )
      await act(() =>
        update(
          context.sqlite,
          context.page.workId,
          { id: row.id, revision: row.revision, scope: rowScope(row) },
          true,
        ),
      );
  }
  const compact = () => context.environment.width() < 600;
  return (
    <Scroll>
      <Box padding={compact() ? "lg" : "x2l"} maxWidth={960}>
        <Column gap="xl" align="stretch">
          <Text
            text="记忆会在下一次模型请求中作为参考。整理建议只有在你应用后才会修改原记忆。"
            tone="muted"
          />
          <Column gap="sm" align="stretch">
            <Row gap="sm" align="center">
              <SearchField
                flex={1}
                placeholder="搜索记忆"
                value={query()}
                debounceMs={300}
                onChange={(e) => filter(() => query.set(e.value))}
              />
              <IconButton
                icon="refresh"
                tooltip="刷新"
                disabled={loading()}
                onPress={reload}
              />
              <Button
                label="新建"
                icon="add"
                disabled={busy()}
                variant="primary"
                onPress={() => edit()}
              />
            </Row>
            <Row gap="sm" align="center">
              <Box width={168}>
                <Select
                  value={scope()}
                  options={[
                    { value: "all", label: "全局与当前作品" },
                    { value: "global", label: "全局" },
                    ...(context.page.workId
                      ? [{ value: "current", label: "当前作品" }]
                      : []),
                  ]}
                  onChange={(e) => filter(() => scope.set(e.value ?? "all"))}
                />
              </Box>
              <Box width={132}>
                <Select
                  value={category()}
                  options={[{ value: "", label: "全部分类" }, ...options]}
                  onChange={(e) => filter(() => category.set(e.value ?? ""))}
                />
              </Box>
            </Row>
          </Column>
          <If when={error() !== ""}>
            <Text text={error()} tone="warning" />
          </If>
          <If when={editing()}>
            <Card padding="lg">
              <Column gap="md" align="stretch">
                <Text
                  text={editId() ? "编辑记忆" : "新建记忆"}
                  variant="heading"
                />
                <TextField
                  testId="memory-content"
                  label="内容"
                  multiline
                  value={content()}
                  disabled={busy()}
                  onChange={(e) => content.set(e.value)}
                />
                <Row gap="sm" align="center">
                  <Box width={168}>
                    <Select
                      value={editScope()}
                      disabled={editId() !== "" || busy()}
                      options={[
                        { value: "global", label: "全局" },
                        ...(context.page.workId
                          ? [{ value: "current", label: "当前作品" }]
                          : []),
                      ]}
                      onChange={(e) => editScope.set(e.value ?? "global")}
                    />
                  </Box>
                  <Box width={132}>
                    <Select
                      value={editCategory()}
                      options={options}
                      disabled={busy()}
                      onChange={(e) => editCategory.set(e.value ?? "fact")}
                    />
                  </Box>
                </Row>
                <Wrap gap="x2l" runGap="sm">
                  <Switch
                    label="核心记忆"
                    value={priority()}
                    disabled={busy()}
                    onChange={(e) => priority.set(e.value)}
                  />
                  <Switch
                    label="加入聊天参考"
                    value={enabled()}
                    disabled={busy()}
                    onChange={(e) => enabled.set(e.value)}
                  />
                </Wrap>
                <Row gap="sm" justify="end">
                  <Button label="取消" disabled={busy()} onPress={close} />
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
              <EmptyState message="没有匹配的记忆" />
            </If>
            <Each items={rows()} key={(row) => row.id}>
              {(row) => (
                <Card padding="lg">
                  <Column gap="sm" align="stretch">
                    <Row gap="xs" align="center">
                      <Badge
                        text={row().work_id === null ? "全局" : "当前作品"}
                        tone="accent"
                      />
                      <Badge
                        text={labels[row().category as keyof typeof labels]}
                        tone="muted"
                      />
                      <If when={row().priority === 1}>
                        <Badge text="核心" tone="success" />
                      </If>
                      <If when={row().enabled !== 1}>
                        <Badge text="已停用" tone="warning" />
                      </If>
                      <Gap flex={1} size="none" />
                      <Text
                        text={`v${row().revision}`}
                        variant="caption"
                        tone="muted"
                      />
                      <Menu
                        items={[
                          { id: "edit", label: "编辑", disabled: busy() },
                          {
                            id: "toggle",
                            label: row().enabled ? "停用" : "启用",
                            disabled: busy(),
                          },
                          {
                            id: "delete",
                            label: "删除",
                            danger: true,
                            disabled: busy(),
                          },
                        ]}
                        onSelect={(e) => choose(row(), e.id)}
                        trigger={
                          <IconButton icon="moreHoriz" tooltip="更多操作" />
                        }
                      />
                    </Row>
                    <Text
                      text={row().content}
                      tone={row().enabled === 1 ? "default" : "muted"}
                    />
                  </Column>
                </Card>
              )}
            </Each>
            <If when={offset() > 0 || more()}>
              <Row gap="sm" align="center" justify="center">
                <Button
                  label="上一页"
                  size="compact"
                  disabled={offset() === 0 || loading()}
                  onPress={() =>
                    offset.update((value) => Math.max(0, value - 20))
                  }
                />
                <Text text={`第 ${offset() / 20 + 1} 页`} tone="muted" />
                <Button
                  label="下一页"
                  size="compact"
                  disabled={!more() || loading()}
                  onPress={() => offset.update((value) => value + 20)}
                />
              </Row>
            </If>
          </Column>
          <Column gap="sm" align="stretch">
            <Text text="待确认的整理建议" variant="heading" />
            <If when={candidates().length === 0}>
              <Text text="暂无整理建议" tone="muted" />
            </If>
            <Each items={candidates()} key={(row) => String(row.id)}>
              {(row) => (
                <Card padding="lg">
                  <Column gap="sm" align="stretch">
                    <Text text={`原记忆：${row().original}`} tone="muted" />
                    <Text text={`建议：${row().content}`} />
                    <If when={row().source_revision !== row().current_revision}>
                      <Text
                        text="原记忆已更新，此建议已过期。"
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
                            resolveSuggestion(
                              context.sqlite,
                              context.page.workId,
                              String(row().id),
                              false,
                            ),
                          )
                        }
                      />
                      <Button
                        label="应用"
                        variant="primary"
                        disabled={
                          busy() ||
                          row().source_revision !== row().current_revision
                        }
                        onPress={() =>
                          act(() =>
                            resolveSuggestion(
                              context.sqlite,
                              context.page.workId,
                              String(row().id),
                              true,
                            ),
                          )
                        }
                      />
                    </Row>
                  </Column>
                </Card>
              )}
            </Each>
          </Column>
          <Card padding="lg">
            <Column gap="sm" align="stretch">
              <Text text="聊天参考预览（全局与当前作品）" variant="heading" />
              <Text text={budget()} variant="caption" tone="muted" />
              <Text text={preview()} />
            </Column>
          </Card>
        </Column>
      </Box>
    </Scroll>
  );
}
