# reveric-plugin-sdk

用于开发 [Reveric](https://github.com/looplj/reveric) 插件的 SDK：类型定义、TSX 页面编译器，以及构建和打包插件的命令行工具 `reveric-plugin`。

本文面向插件开发者，以及代替开发者编写插件的 AI agent。读完后应该能写出一个完整的插件，包括清单、入口、工具、提示词、定时任务、私有数据库和界面。

类型定义是最终依据：

- `reveric-plugin-sdk`（`index.d.ts`）：入口、上下文、宿主 API 的类型和行为说明
- `reveric-plugin-sdk/ui`（`ui.d.ts`）：TSX 页面可用的组件和属性

本文与类型注释不一致时，以类型注释为准。

## 1. 快速开始

需要 Node.js 22 或更高版本。

### 创建项目

```sh
mkdir my-plugin && cd my-plugin
npm init -y
npm install -D reveric-plugin-sdk
```

`package.json` 中加入：

```json
{
  "type": "module",
  "scripts": {
    "build": "reveric-plugin build",
    "pack": "reveric-plugin pack"
  }
}
```

`tsconfig.json`：

```json
{
  "extends": "reveric-plugin-sdk/tsconfig.base.json",
  "include": ["src"]
}
```

### 项目结构

```
my-plugin/
  plugin.json          # 清单
  src/index.ts         # 入口，导出 apply
  src/views/<name>.tsx # 可选：TSX 页面
  views/*.json         # 可选：reveric-ui-v1 页面和工具卡片
  migrations/*.sql     # 可选：私有数据库迁移
  tsconfig.json
  package.json
```

这些路径是约定，构建工具按这个结构查找文件，不需要额外配置。

### 最小插件

`plugin.json`：

```json
{
  "id": "example.hello",
  "name": { "zh-CN": "你好", "en": "Hello" },
  "version": "1.0.0",
  "pluginApiVersion": "^1",
  "main": "dist/index.js"
}
```

`src/index.ts`：

```ts
import type { PluginSetup } from "reveric-plugin-sdk";

export function apply(setup: PluginSetup) {
  setup.tools.register({
    name: "HelloGreet",
    description: "Greet a person by name.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["name"],
      properties: { name: { type: "string", minLength: 1 } },
    },
    async handler(input) {
      return { greeting: `Hello, ${input.name}!` };
    },
  });
}
```

### 构建与打包

```sh
npm run build   # 类型检查，并构建到 build/
npm run pack    # 构建，并打包成 example.hello-1.0.0.zip
```

把 ZIP 导入 Reveric 即可使用。构建工具会做以下事情：

- 用 `tsconfig.json` 做类型检查。
- 把 `src/index.ts` 打包成 `dist/index.js`。
- 把每个 `reveric-tsx-v1` 页面从 `src/views/<name>.tsx` 编译成 `dist/views/<name>.js`。
- 原样复制 `views/` 目录、`reveric-ui-v1` 页面声明的 JSON 文件和数据库迁移。

限制：入口和每个页面产物各不超过 2 MB；ZIP 压缩后不超过 10 MB，解压后不超过 20 MB，最多 500 个文件。超出时构建会直接报错。

在代码里调用构建也可以：`import { buildPlugin, packPlugin } from "reveric-plugin-sdk/build"`。

## 2. 清单 plugin.json

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `id` | 是 | 匹配 `^[a-z0-9]+(\.[a-z0-9-]+)+$`，如 `vendor.name` |
| `name` | 是 | 显示名称，`PluginText`（见下文） |
| `description` | 否 | 描述，`PluginText` |
| `version` | 是 | 语义化版本，如 `1.2.0` |
| `pluginApiVersion` | 是 | 写 `"^1"` |
| `main` | 是 | 固定为 `"dist/index.js"` |
| `author` | 否 | 字符串 |
| `defaultEnabled` | 否 | 安装后是否默认启用，默认 `false` |
| `platforms` | 否 | `windows`、`macos`、`android` 的子集，默认全部 |
| `permissions` | 否 | 需要的权限，见下表 |
| `settings` | 否 | 设置表单字段和设置动作 |
| `database` | 否 | 私有 SQLite 数据库及迁移 |
| `pages` | 否 | 插件页面 |
| `tasks` | 否 | 定时任务 |

**PluginText**：面向用户的文本可以是字符串，也可以是按语言区分的对象，如 `{ "zh-CN": "记忆", "en": "Memory" }`。宿主按"当前界面语言 → zh-CN → en → 第一项"的顺序选择。

**权限**：

| 权限 | 允许 |
| --- | --- |
| `ai.generateText` | `context.ai.listModels()` / `generateText()` |
| `chapters.read` / `chapters.write` | 读取 / 修改当前作品的章节 |
| `characters.read` / `characters.write` | 读取 / 修改当前作品的角色 |

未声明或用户未授权的权限，调用时会以 `permission_denied` 失败。

### settings

```json
"settings": {
  "fields": {
    "apiKey": { "type": "secret", "title": "API Key", "required": true },
    "limit": { "type": "integer", "title": "结果数", "default": 10, "min": 1, "max": 50 },
    "model": { "type": "model", "title": "使用的模型" }
  },
  "actions": {
    "verifyApiKey": { "title": "验证 API Key", "requires": ["apiKey"] }
  }
}
```

- 字段名匹配 `^[A-Za-z][A-Za-z0-9_]*$`。
- `type` 可选：`string`、`text`（多行）、`integer`、`number`、`boolean`、`select`（配 `options: [{ value, label }]`）、`secret`、`model`。
- 其他可选属性：`description`、`required`、`default`、`maxLength`（文本类）、`min` / `max`（数字类）。
- `secret` 用 `context.secrets.get(key)` 读取，其他字段用 `context.settings.get(key)` 读取。
- `model` 字段的值是 `{ providerId, model }`，可以直接传给 `ai.generateText`；未设置时为 `null`，此时会使用用户的默认聊天模型。
- `actions` 是设置页上的按钮，比如"验证 API Key"。`requires` 列出执行前必须已填写的字段。

### database

```json
"database": {
  "version": 2,
  "migrations": [
    { "version": 1, "source": "migrations/001.sql" },
    { "version": 2, "source": "migrations/002.sql" }
  ]
}
```

迁移必须从 1 开始连续编号，数量等于 `version`。已发布的迁移不要再修改；改表结构时新增一个迁移，并把 `version` 加一。

### tasks

```json
"tasks": {
  "organize": { "title": "整理记忆", "intervalMinutes": 60 }
}
```

任务 ID 匹配 `^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$`，`intervalMinutes` 取值 15–10080。用户也可以在设置页手动触发任务。

### pages

见第 6 节。

## 3. 入口与注册

入口文件导出 `apply(setup)`。`apply` 只能注册处理函数，此时不能调用任何宿主 API，也拿不到数据。

| 注册方法 | 用途 |
| --- | --- |
| `setup.tools.register(tool)` | 注册 Agent 可调用的工具 |
| `setup.prompts.context(provider)` | 每次模型请求前，向对话追加参考资料 |
| `setup.prompts.system(provider)` | 替换指定会话模式的整个系统提示词 |
| `setup.tasks.register(id, handler)` | 绑定清单中声明的定时任务 |
| `setup.settings.registerAction(name, handler)` | 绑定清单中声明的设置动作 |
| `setup.pages.registerAction(pageId, name, handler)` | 绑定 `reveric-ui-v1` 页面声明的 action |

规则：

- 清单中声明的每个任务、设置动作和页面 action 都必须且只能注册一次。缺少、多余或重复注册都会导致插件激活失败。
- 工具和提示词只在代码中注册，不需要写进清单。
- 模块级变量只能当缓存用。插件更新、停用或运行时重建后，模块状态都会丢失；需要持久保存的数据写进 `storage` 或 `sqlite`。
- 不要把某次调用拿到的 `context` 留给之后的调用使用。

### 工具

```ts
setup.tools.register({
  name: "MemorySearch",          // /^[A-Za-z][A-Za-z0-9_]{0,63}$/，与其他工具不重名
  description: "Search saved memories by text.",
  inputSchema: {
    type: "object",
    additionalProperties: false,
    properties: {
      query: { type: "string", maxLength: 200 },
      limit: { type: "integer", minimum: 1, maximum: 50 },
    },
  },
  display: { title: { "zh-CN": "搜索记忆", en: "Search memories" }, summaryArg: "query" },
  async handler(input, context) {
    const rows = await context.sqlite.query({
      sql: "SELECT id, content FROM memories WHERE content LIKE ? LIMIT ?",
      params: [`%${input.query ?? ""}%`, Number(input.limit ?? 20)],
    });
    return { items: rows };
  },
});
```

- 时限 60 秒；返回值必须是严格 JSON 对象，不超过 256 KB。
- `description` 和 `inputSchema` 会发给模型，写清楚每个参数的含义和取值范围。
- 返回值不能包含 `bigint`、`Uint8Array`、`Date`、`NaN` 等非 JSON 值。SQLite 查询结果中可能有 `bigint`，返回前要转换。

### 提示词

```ts
setup.prompts.context({
  id: "memory",
  async handler(context) {
    const rows = await context.sqlite.query({ sql: "SELECT content FROM memories LIMIT 20" });
    return rows.length ? rows.map((r) => `- ${r.content}`).join("\n") : null;
  },
});
```

- `context` 提供者在每次模型请求前运行。返回的文本只在和上一次不同时才会加入对话；返回 `null` 表示当前没有内容。
- 每个插件最多 1000 token，所有插件合计 2000 token。
- 提示词上下文是只读的：只有 `sqlite.query`、`storage.get` 和 `settings`。
- `request.agentId` 和 `request.mode` 说明这次请求来自哪个 agent、哪种会话模式。不想处理时返回 `null`。

### 定时任务

```ts
setup.tasks.register("organize", async (context) => {
  const changed = await organize(context);
  return { summary: `整理了 ${changed} 条` };
});
```

时限：总共 5 分钟，连续执行 JS 不超过 2 秒，所以耗时的计算要拆开、穿插 `await`。`summary` 会显示在设置页。

### 设置动作

```ts
setup.settings.registerAction("verifyApiKey", async (context) => {
  const key = await context.secrets.get("apiKey");
  const response = await context.http.fetch("https://api.example.com/me", {
    headers: { Authorization: `Bearer ${key}` },
  });
  return response.status === 200 ? { ok: true } : { ok: false, code: "unauthorized" };
});
```

设置动作在插件停用时也能运行，`settings.get` / `secrets.get` 读到的是表单中尚未保存的值。返回的 `code` 为 `unauthorized`、`network`、`timeout` 时，宿主会显示对应的说明。

## 4. 宿主 API

处理函数收到的 `context` 按阶段提供下列 API，完整签名见 `index.d.ts`：

| API | 说明 |
| --- | --- |
| `context.plugin` | `{ id, version }` |
| `context.log.info/warn/error(message, data?)` | 写宿主日志，不会抛错，已知密钥会被脱敏 |
| `context.http.fetch(url, init?)` | HTTP 请求，支持 `timeoutMs`、`maxBytes`、`responseType: "base64"` |
| `context.storage.get/set/remove(key)` | 插件私有的 JSON 键值存储 |
| `context.settings.get(key)` / `context.secrets.get(key)` | 读取设置 |
| `context.sqlite.query/execute/transaction` | 私有 SQLite，需要声明 `database` |
| `context.ai.listModels()` / `generateText(input)` | 调用用户配置的聊天模型，需要 `ai.generateText` 权限 |
| `context.chapters` / `context.characters` | 当前作品的章节 / 角色：`list`、`get`、`update` |

SQLite：

- 参数用 `?` 占位，通过 `params` 传入，不要拼接 SQL。
- 超出安全整数范围的数用 `bigint`；二进制用 `Uint8Array`。
- 相关的多条写入放进一个 `transaction`，保证原子性。

修改章节时要带上读取到的版本号：

```ts
const chapter = await context.chapters.get({ id });
await context.chapters.update({
  id,
  expectedVersion: chapter.version,
  patch: { outline: newOutline },
});
```

## 5. 错误处理

预期内的失败抛出 `PluginError`，错误码匹配 `/^[a-z][a-z0-9_]{0,63}$/`：

```ts
import { PluginError } from "reveric-plugin-sdk";

if (!query) throw new PluginError("invalid_argument", "query is required");
```

- 工具调用会把 `{ ok: false, error_code, error }` 返回给 Agent，所以错误信息要写清楚原因和处理方法，方便 Agent 自行修正。
- 宿主 API 调用失败时抛出 `PluginHostError`，用 `isHostError` 判断错误码：

```ts
import { isHostError } from "reveric-plugin-sdk";

try {
  await context.chapters.update({ id, expectedVersion, patch });
} catch (error) {
  if (isHostError(error, "version_conflict")) {
    throw new PluginError("stale", "Chapter changed; read it again before updating");
  }
  throw error;
}
```

常见宿主错误码：`invalid_argument`、`permission_denied`、`invalid_scope`（没有当前作品）、`not_found`、`version_conflict`、`draft_conflict`、`too_large`、`network`、`timeout`、`unavailable`。

## 6. 界面

插件有两种界面协议，按需求选择：

| 需求 | 协议 |
| --- | --- |
| 纯展示：信息页、工具结果卡片、点一下就整体刷新的简单操作 | `reveric-ui-v1` |
| 动态交互：输入、筛选、编辑草稿、即时反馈 | `reveric-tsx-v1` |

`reveric-ui-v1` 不需要编译，也不需要单独的运行时，能满足需求时优先用它。工具结果卡片只支持 `reveric-ui-v1`。

### 6.1 reveric-ui-v1：纯展示

界面用 A2UI JSON 消息描述。清单声明：

```json
"pages": {
  "report": {
    "title": "报告",
    "location": "home.plugin",
    "protocol": "reveric-ui-v1",
    "source": "views/report.json",
    "actions": ["load", "refresh"],
    "onMount": "load"
  }
}
```

- `source` 是包内的 `.json` 文件，建议放在 `views/` 目录。第一条消息必须是 `createSurface`，之后可以跟 `updateComponents` / `updateDataModel`。
- `actions` 是界面可以触发的动作名；`onMount` 指定页面打开时自动执行哪一个。

在 `apply` 中绑定 action。处理函数返回消息数组，总大小不超过 1 MB：

```ts
setup.pages.registerAction("report", "load", async (data, event, context) => [
  { version: "v1.0", updateDataModel: { path: "/rows", value: await loadRows(context) } },
]);
```

工具结果卡片：注册工具时设置 `display.view`，并且必须同时设置 `display.result`：

```ts
display: {
  result: "json",
  view: { protocol: "reveric-ui-v1", source: "views/card.json" },
}
```

### 6.2 reveric-tsx-v1：动态页面

#### 声明与构建

```json
"pages": {
  "manage": {
    "title": "管理",
    "location": "home.plugin",
    "protocol": "reveric-tsx-v1",
    "source": "dist/views/manage.js"
  }
}
```

`source` 必须是 `dist/views/<name>.js`，对应的源文件是 `src/views/<name>.tsx`。构建时会检查组件和属性的类型，并把默认导出的组件包装成宿主需要的入口。

TSX 页面不能声明 `actions` 和 `onMount`，状态和加载逻辑都写在页面代码里。

#### 页面组件

页面文件默认导出一个函数，参数是 `PageContext`：

```tsx
import { Button, Column, Text, TextField, signal, type PageContext } from "reveric-plugin-sdk/ui";

export default function Page(context: PageContext) {
  const name = signal("");
  const saved = signal(false);

  async function save() {
    await context.storage.set("name", name());
    saved.set(true);
    await context.view.setDirty(false);
  }

  return (
    <Column gap="md" align="stretch">
      <TextField
        label="名字"
        value={name()}
        onChange={(e) => {
          name.set(e.value);
          void context.view.setDirty(true);
        }}
      />
      <Button label="保存" variant="primary" onPress={save} />
      <Text text={saved() ? "已保存" : ""} tone="muted" />
    </Column>
  );
}
```

要点：

- `Page` **只执行一次**。之后的界面更新完全由 signal 驱动，不会重新运行 `Page`。
- 属性里直接写 `value={name()}` 即可，编译器会让它随 signal 自动更新，不需要包成函数。
- 需要随状态变化的逻辑写在 `computed`、`effect` 或 JSX 属性里，不要在 `Page` 函数体中读取 signal 后据此分支。

#### 状态与副作用

| API | 用法 |
| --- | --- |
| `signal(v)` | `s()` 读，`s.set(v)` / `s.update(fn)` 写 |
| `computed(fn)` | 派生值 |
| `effect(fn)` | 依赖变化时重新执行，不能是 async |
| `resource(source, load)` | 异步加载：`value()`、`loading()`、`error()`、`refetch()` |
| `batch(fn)` | 合并多次写入 |
| `untracked(fn)` | 读取但不建立依赖 |
| `cleanup(fn)` | 页面关闭时执行，用于取消定时器等 |

异步加载优先用 `resource`。`source` 变化时会自动重新加载，并丢弃过期的结果：

```tsx
const query = signal("");
const results = resource(() => query(), (q) => search(context.sqlite, q));
// results.loading()、results.value()
```

#### 页面上下文

`PageContext` 包含宿主 API（`sqlite`、`storage`、`settings`、`http`、`ai`、`chapters`、`characters`、`log`），以及：

- `context.page`：`{ viewId, instanceId, workId }`，`workId` 在作品外为 `null`。
- `context.environment`：`width()`、`height()`、`platform()`、`theme()`、`locale()`、`visible()`，每个字段单独追踪变化。页面不可见时可以暂停加载：

  ```ts
  effect(() => {
    if (!context.environment.visible()) return;
    reload();
  });
  ```

- `context.ui.toast({ message })`
- `context.ui.dialog({ title, message?, confirmLabel?, tone? })`：返回用户是否确认。删除等危险操作用 `tone: "danger"`。
- `context.ui.navigate({ viewId })`：跳转到同一插件的其他页面。
- `context.view.setDirty(value)`：有未保存的修改时设为 `true`，关闭页面前宿主会先询问用户。

#### 控制流

```tsx
<If when={items().length === 0} fallback={<Text text="有内容" />}>
  <EmptyState message="暂无内容" />
</If>

<Each items={items()} key={(item) => item.id}>
  {(item) => <Text text={item().title} />}
</Each>

<Column align="stretch">
  <List flex={1} items={rows()} key={(r) => r.id} itemExtent={32}
        renderItem={(row) => <Text text={row().label} />} />
</Column>

<ErrorBoundary fallback={(error, reset) => <Button label="重试" onPress={reset} />}>
  <Content />
</ErrorBoundary>
```

- `Each` 和 `List` 回调里的 `item` / `index` 是 accessor，要写成 `item()`。
- `List` 是虚拟列表，用于大量条目，行高必须固定（`itemExtent`）。不传 `height` 时填满父容器；放在 `Scroll` 里时必须传 `height`。
- 条目不多时用 `Each`，不需要固定行高。

#### 组件

| 类别 | 组件 |
| --- | --- |
| 布局 | `Column`、`Row`、`Wrap`、`Box`、`Scroll`、`Gap` |
| 展示 | `Text`、`Markdown`、`Icon`、`Card`、`Divider`、`Badge`、`Loading`、`EmptyState` |
| 输入 | `Button`、`IconButton`、`TextField`、`SearchField`、`Select`、`Checkbox`、`Switch` |
| 容器 | `Tabs`、`Collapsible`、`Menu`、`Dialog`、`Popover` |

各组件的属性见 `ui.d.ts`。样式只能用设计 token，例如间距 `gap="md"`、语气色 `tone="muted"`、按钮 `variant="primary"`，不能传颜色值或任意样式。所有组件都支持 `testId`、`accessibleLabel` 和 `flex`（在 `Row` / `Column` 中按比例分配剩余空间）。

#### 事件

事件参数是对象，类型由组件决定：

| 组件 | 事件 | 参数 |
| --- | --- | --- |
| `Button`、`IconButton` | `onPress` | `{}` |
| `TextField`、`SearchField` | `onChange`、`onSubmit` | `{ value: string }` |
| `Select` | `onChange` | `{ value: string \| null }` |
| `Checkbox`、`Switch` | `onChange` | `{ value: boolean }` |
| `Tabs` | `onChange` | `{ value: string }` |
| `Menu` | `onSelect` | `{ id: string }` |
| `Dialog`、`Popover`、`Collapsible` | `onOpenChange` | `{ open: boolean }` |

输入组件都是受控组件：`value` 由页面持有，在 `onChange` 中写回，否则输入不会生效。事件处理函数可以是 async，抛出的错误会交给最近的 `ErrorBoundary`。

#### TSX 写法限制

编译器会拒绝以下写法：

| 错误写法 | 正确写法 |
| --- | --- |
| `<div>`、`<span>` 等 DOM 标签 | 使用 `reveric-plugin-sdk/ui` 的组件 |
| `<Column>文字</Column>` | `<Column><Text text="文字" /></Column>` |
| `<Card><A /><B /></Card>`（单子节点组件传多个） | `<Card><Column><A /><B /></Column></Card>` |
| `<Button {...props} />` | 逐个写出属性 |
| 在 `effect` 中使用 async 函数 | 用 `resource`，或在 effect 里调用异步函数并处理 Promise |

只接受一个子节点的组件：`Box`、`Scroll`、`Card`，以及 `Dialog` 的 `body`、`Popover` 的 `body`、`Menu` 的 `trigger`。

其他限制：单个页面产物不超过 2 MB，组件树深度不超过 32 层。页面运行在独立的运行时中，不和入口 `apply` 共享模块状态。

## 7. 测试

宿主 API 无法在 Node 中直接调用，所以建议把业务逻辑写成接收 `PluginSqlite` 等接口的函数，测试时传入替身。例如用 `node:sqlite` 实现 `PluginSqlite`：

```ts
import { DatabaseSync } from "node:sqlite";
import type { PluginSqlite } from "reveric-plugin-sdk";

const raw = new DatabaseSync(":memory:");
const sqlite: PluginSqlite = {
  async query({ sql, params = [] }) {
    return raw.prepare(sql).all(...params) as never;
  },
  async execute({ sql, params = [] }) {
    const r = raw.prepare(sql).run(...params);
    return { changes: Number(r.changes), lastInsertRowId: BigInt(r.lastInsertRowid) };
  },
  async transaction(statements) {
    raw.exec("BEGIN");
    try {
      const results = [];
      for (const s of statements) results.push(await sqlite.execute(s));
      raw.exec("COMMIT");
      return results;
    } catch (e) {
      raw.exec("ROLLBACK");
      throw e;
    }
  },
};
```

测试文件可以先用 esbuild（SDK 已依赖）打包成 `.mjs`（`platform: "node"`、`format: "esm"`），再用 `node --test` 运行。Reveric 仓库中的 `plugins/memory/test/` 是完整示例。

## 8. 提交前检查

- [ ] `plugin.json` 的 `id`、`version`、`pluginApiVersion: "^1"`、`main: "dist/index.js"` 都已填写
- [ ] 用到的权限、设置、数据库都已在清单中声明
- [ ] 清单中声明的每个任务、设置动作和页面 action 都在 `apply` 中注册了且只注册一次
- [ ] 工具返回的是严格 JSON，没有 `bigint`
- [ ] 预期内的失败用 `PluginError`，错误信息能帮 Agent 修正输入
- [ ] 改了已发布的数据库结构时，新增了迁移并提升了 `database.version`
- [ ] TSX 页面默认导出 `Page`，输入组件都在 `onChange` 中写回了 `value`
- [ ] 有未保存修改的页面调用了 `context.view.setDirty`
- [ ] `npm run pack` 通过（包含类型检查），测试通过
