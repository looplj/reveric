# 设置、状态、存储与安装

> 本篇定义“设置 / 插件”页面、插件状态、配置与凭据、数据库表、zip 安装与备份。任务进度只在[实施任务](README.md#实施任务)维护。

## 设置 / 插件

桌面端设置对话框和移动端设置页各新增“插件”入口，排在 MCP 之后。两端共用同一份页面内容。

| 里程碑 | 页面内容 |
| --- | --- |
| M1 | 插件列表：名称、版本、来源（内置 / 本地）、状态、开关；展开后显示描述、作者、当前提供的工具及其是否被其他插件覆盖、失败原因 |
| M2 | 增加：安装按钮（选择 zip）、配置表单、权限列表及撤销、更新（安装同 ID 新版本）、卸载（仅本地插件） |
| M3 | 增加任务启停、立即运行、取消、最近结果、下次运行与模型用量；展示私有库占用和迁移失败原因。记忆管理在独立 TSX 页面，见[自定义 View](views.md) |

不单独出设计稿，沿用现有设置页（如 MCP 设置）的列表、开关和详情样式实现。

### 插件状态

启用意愿与运行状态分开：用户打开开关不代表配置已齐全或运行时已就绪。

| 状态 | 条件 | 能力可用 |
| --- | --- | --- |
| 已关闭 | `enabled` 为 false | 否 |
| 当前平台不支持 | `platforms` 不含当前平台 | 否 |
| 待配置 | 已开启，但必填配置缺失（M2） | 否 |
| 激活中 | 正在执行激活 | 否 |
| 可用 | 激活成功 | 是 |
| 失败 | 清单无效、API 版本不兼容、激活失败或工具名冲突 | 否，显示原因 |

运行状态只保存在内存中，按 `enabled`、平台、配置完整性和激活结果计算；失败原因显示在设置页并写日志，不改变 `enabled`。

## 配置与凭据

M2 交付。插件在清单 `settings.fields` 中声明配置字段，Host 负责表单、校验、持久化和运行时读取。

| `type` | 控件 | 其他属性 |
| --- | --- | --- |
| `string` | 单行输入 | `default`、`required`、`maxLength` |
| `text` | 多行输入 | `default`、`required`、`maxLength` |
| `integer`、`number` | 数字输入 | `default`、`required`、`min`、`max` |
| `boolean` | 开关 | `default` |
| `select` | 下拉选择 | `default`、`required`、`options: [{ value, label }]` |
| `secret` | 密钥输入 | `required` |

所有字段都有 `title`，可选 `description`。`title`、`description` 和 `select` 选项的 `label` 是 `PluginText`：字符串对所有语言显示，对象按语言标签提供多份，Host 依次取当前界面语言、zh-CN、en、第一项。

插件对外只声明上表这种简化的 `settings.fields`，不提供 A2UI 界面：表单必须在执行插件前就能展示，凭据的不回显、替换和清除由 Host 统一处理，插件之间的配置体验也保持一致。Host 内部把 `settings.fields` 转换成 A2UI 消息，使用[A2UI 渲染器](views.md#a2ui-页面与声明式界面)。插件页面可选 TSX 或 A2UI；两者复用底层 Reveric Widget，不共用页面状态或协议：

| 部分 | 实现 |
| --- | --- |
| 字段模型与校验 | `lib/shared/models/plugin/setting_field.dart`：`parsePluginSettingFields` 解析清单 `settings.fields`（已知属性类型错误、默认值不合规、`min > max`、选项重复等抛 `FormatException`，未知属性忽略）；`validatePluginSettingValue` 是保存前的唯一校验规则，T-09 的 service 写入前复用 |
| 表单 | `lib/shared/widgets/settings/plugins/config_form.dart` 的 `PluginConfigForm`：输入 `fields`、已保存的普通配置、已保存凭据的字段名和 `onSave` 回调；T-09 把它放进设置页，并在 `onSave` 中持久化 |
| 消息生成 | `config_surface.dart`：字段到组件的映射（`string` / `text` / `integer` / `number` / `secret` 用 TextField 的对应变体，`boolean` 用 Switch，`select` 用 ChoicePicker），以及把页面数据读回为提交内容 |

- 校验规则只在 Dart 侧维护一份：页面数据每次变化后，Host 用 `validatePluginSettingValue` 重算各字段，结果写入页面数据的 `/valid`，组件的 checks 只引用这些路径。字段在用户编辑后显示错误，保存按钮在全部规则通过前禁用；保存时再完整校验一次。
- 凭据原文不进入页面数据：输入框初始为空，已保存时占位提示「已设置，留空则保持不变」并显示「清空」。清空只标记待清除，点保存后才生效；必填凭据清空后要重新填写才能保存。`onSave` 收到的凭据只包含有变更的字段：新值或 `null`（清除）。
- 保存失败时表单显示「保存失败」，保留用户输入；底层错误只写日志。

插件处理函数从自己阶段的上下文按需读取（`apply` 收到的 `setup` 没有这些接口）：

```js
const apiKey = await context.secrets.get("apiKey");
const maxResults = await context.settings.get("maxResults");
```

上下文已经绑定插件身份，两个读取接口只能访问当前插件的数据。凭据与普通配置一样保存在应用数据库中，不引入系统钥匙串或其他安全存储依赖；分开保存是为了让凭据不回显、不进入日志，而不是为了加密。

| 情况 | 预期行为 |
| --- | --- |
| 必填配置缺失 | 显示“待配置”，插件能力不可调用 |
| Key 已保存 | 设置页显示“已设置”，不回显原文，支持替换和清除 |
| Key 被替换 | 下一次调用读取最新值，不要求重启 |
| Key 被清除 | 必填时转为待配置，阻止新的调用 |
| 插件关闭 | 保留普通配置和凭据，停止提供能力 |
| 保存失败 | 明确提示失败，不把未保存值显示为已生效 |

配置完整与凭据有效是两件事，保存配置不发出网络请求。Key 不进入模型的工具参数、插件页面的渲染属性与事件载荷、日志或工具结果（Host 配置表单的页面数据只临时持有用户正在输入的新值，保存后即清空）；Agent 只传业务参数，插件执行时通过上下文的 `secrets` 取 Key。

## 设置页操作

插件可以在设置页提供需要执行插件代码的操作，例如验证 API Key。清单 `settings.actions` 声明操作，处理函数在 `apply` 中注册：

```json
{
  "settings": {
    "fields": {
      "apiKey": { "type": "secret", "title": "API Key", "required": true }
    },
    "actions": {
      "verifyApiKey": {
        "title": { "en": "Verify API Key", "zh-CN": "验证 API Key" },
        "requires": ["apiKey"]
      }
    }
  }
}
```

```ts
export function apply(setup: PluginSetup) {
  setup.settings.registerAction("verifyApiKey", async (context) => {
    const apiKey = await context.secrets.get("apiKey"); // 表单中尚未保存的值
    // ...
    return { ok: true };
  });
}
```

- `title` 是 `PluginText`；`requires` 只能列出已声明的配置字段，这些字段都有合法值时操作按钮才可点击。
- 清单中声明的每个操作都必须用 `setup.settings.registerAction(name, handler)` 注册，且不能注册未声明的名称；Host 在每次 `apply` 后核对注册的操作名与清单，不一致则失败。
- 处理函数收到 `ActionContext`：`callId` 加 `PluginServices`；其中 `settings.get` 和 `secrets.get` 返回设置表单中尚未保存的值，便于保存前验证。插件未开启时也可以执行，时间限制见 SDK。
- 返回 `ActionResult`（`{ok, code?, message?}`）。`code` 为 `unauthorized`、`network`、`timeout` 时使用宿主文案，其他 code 显示为通用失败；`message` 只写日志，不显示给用户。抛出带合法 code 的 `PluginError` / `PluginHostError` 等同返回该 code；超时报告 `timeout`，其他未捕获异常报告 `plugin_error`。
- 接口定义以 [`plugins/sdk/index.d.ts`](../../../plugins/sdk/index.d.ts) 中的 `PluginSetup.settings`、`ActionContext`、`ActionResult` 为准。
## 数据库

M3 的 Host 调度状态另见[调度持久化](prompts-and-tasks.md#调度持久化与公平性)。

本节是 Host 登记、权限、KV 与凭据表；插件自定义结构化数据使用后文的[私有 SQLite](#插件私有-sqlite)，不能把私有表建进主库。

### 表结构

四张表都在 app 库（`reveric.sqlite`）中，内置插件和第三方插件使用同样的表和规则，不为内置插件预置数据或单独的开关存储。

| 表 | 主键 | 字段 | 职责 |
| --- | --- | --- | --- |
| `plugin_registry` | `plugin_id` | `version`、`source`、`package_path`、`enabled`、`created_at`、`updated_at`、`deleted_at` | 已知插件、当前版本、包位置和用户启停选择 |
| `plugin_permissions` | `plugin_id` + `permission` | `created_at`、`updated_at`、`deleted_at` | 用户对插件的授权记录 |
| `plugin_storage` | `plugin_id` + `key` | `value`（JSON 文本）、`created_at`、`updated_at`、`deleted_at` | 插件普通配置和插件自己的数据 |
| `plugin_secrets` | `plugin_id` + `key` | `value`、`created_at`、`updated_at` | API Key 等凭据，单独成表以便排除日志和回显 |

- `source`：`bundled` 随应用打包，`local` 用户安装。只用于找到插件包和决定能否卸载；加载、注册、启停、权限和配置的流程不按来源分支。
- `package_path`：内置插件为资源路径（如 `assets/plugins/reveric.web`），本地插件为相对应用数据目录的路径（如 `plugins/example.search/1.2.0`），备份恢复到其他设备后仍然有效。
- `plugin_storage` 中，配置字段的 key 为 `settings.<字段名>`，`storage` API 的 key 为 `data.<key>`，两者互不可见。
- 单条 `plugin_storage.value` 不超过 256 KB，单个插件的 `data.*` 合计不超过 16 MB，超出时 `storage.set` 抛 `too_large`。
- 表结构只用列和主键声明，不使用外键、CHECK 等约束；`source` 等取值范围在 Dart 侧校验。时间戳使用 `dateTime()`。
- 所有 DAO 方法都带 `pluginId` 参数，查询都按 `plugin_id` 过滤。

### Migration

核对结果（2026-10-30）：最新正式发布 tag `v0.4.0` 中 app 库 `currentSchemaVersion` 为 1，当前分支同为 1，即当前 schema 已发布。因此新增四张表需要把 app 库升到 2，并在 `onUpgrade` 中增加 `from < 2` 的建表步骤。实施时如果当前分支已有尚未发布的 2，则把建表并入该版本。

当前代码的 app 库 `currentSchemaVersion` 为 3：`from < 2` 新建 `plugin_registry`、`plugin_storage`、`plugin_secrets`；`from < 3` 新建 `plugin_permissions`、`plugin_tasks` 及其索引，为已有的 `plugin_storage` 补 `deleted_at`，并删除旧 `memories` 表。下方 1 → 2 的步骤是最初计划，以代码为准。

```text
from version 1 to 2:
1. create table plugin_registry
2. create table plugin_permissions
3. create table plugin_storage
4. create table plugin_secrets
```

只新建表，不改动已有表和数据；新表初始为空，内置插件在首次启动时登记。降级打开新库时由现有版本检查拒绝。migration 测试使用 `v0.4.0` 的真实 app 库 fixture 升级到 2，断言 `user_version`、四张表结构与主键，以及已有表记录数不变。

## 状态规则

- **登记**：Host 启动时扫描内置插件。没有登记记录的插件按清单中的 `defaultEnabled` 写入 `plugin_registry`；用户安装的插件在安装完成时写入，`enabled` 为 false，用户开启后才运行。
- **启停**：用户开关只改 `enabled`。登记记录一经写入，后续启动和应用升级不再按 `defaultEnabled` 覆盖用户选择。
- **版本更新**：随应用升级的内置插件与用户更新的第三方插件同样处理：比较清单版本，更新 `version` 和 `package_path`，保留启停选择、配置和授权；新增权限需要用户确认后才激活。
- **授权**：用户确认后写入 `plugin_permissions`；撤销时设置 `deleted_at`，重新授权时清空该字段。
- **卸载**：只允许卸载 `source = local` 的插件，在 `plugin_registry` 上设置 `deleted_at`，保留配置、凭据和授权记录，重新安装同一 ID 时恢复。

## 安装、更新与卸载

M2 交付。安装包为 zip。

### 包格式

```text
example-search-1.2.0.zip
  plugin.json
  dist/index.js
  其他资源
```

- `plugin.json` 必须在 zip 根目录。
- zip 不超过 10 MB，解压后合计不超过 20 MB，条目不超过 500 个。
- 拒绝绝对路径、包含 `..` 的路径和符号链接条目。

### 安装与更新流程

```text
1. 用户在“设置 / 插件”选择 zip（按项目文件访问规则处理移动端路径）
2. 解压到临时目录，校验包格式、清单、pluginApiVersion、main 文件和大小；不执行插件代码
3. 同 ID 已安装时：新版本号必须高于当前版本；比较权限，列出新增权限
4. 展示插件信息与权限（更新时只列新增权限），用户确认；M3 更新同时确认未保存页面，取消则中止
5. M3 更新先阻止新开页面并关闭旧页面会话，再移动到 plugins/<id>/<version>/
6. 在一个事务中写入或更新 plugin_registry，并写入授权记录
7. 更新时删除旧版本目录 plugins/<id>/<旧版本>/
8. 新安装保持关闭；更新时若插件已开启，用新版本重新激活
```

以下是无私有数据库插件的基础流程；声明 database 的插件在 M3 使用[插件 schema 与更新](#插件-schema-与更新)的副本迁移和可恢复切换流程。

提交前任一步失败时，删除临时目录，数据库和已安装版本保持不变，原版本继续可用。第 6 步失败时同时删除第 5 步移入的新版本目录。第 7 步在第 6 步事务提交后执行，此时登记记录已指向新版本；正在执行的调用已把入口代码读入内存，不受影响。删除旧版本目录失败时只记录日志，不影响更新结果，下次启动时清理 `plugins/<id>/` 下非当前版本的目录。删除范围只限插件包文件，不涉及配置、凭据、授权和业务数据。

更新失败恢复原版本的页面打开能力，已经关闭的页面不自动重建未保存草稿。M3 的页面会话释放与确认规则见[生命周期](views.md#生命周期与资源限制)。

当前平台不在 `platforms` 中时允许安装，状态显示“当前平台不支持”。

### 卸载

M3 卸载前先确认未保存页面，取消则中止卸载；确认后关闭页面及其运行时。卸载只设置 `plugin_registry.deleted_at` 并移除注册项，不删除插件目录、配置、凭据和授权记录。重新安装同一 ID 时清空 `deleted_at`，恢复原有设置。

## 备份

备份对整个 app 库打包，因此插件表（包括 `plugin_secrets`）随备份保存，与 AI 供应商 Key 的现状一致。M2 把 `plugins` 目录加入备份目录列表；M3 增加 `plugin_data` 一致性快照和任务状态，详见[备份、停用与卸载](#备份停用与卸载)。恢复后本地插件包和登记记录对应；恢复不改变插件的启停选择。

## 改动清单

#### `lib/shared/database/app_database.dart`（M1）
- 新增插件表定义与 `onUpgrade` 建表步骤；当前 `currentSchemaVersion` 为 3，见上文 Migration。

#### NEW: `lib/shared/database/daos/plugin_dao.dart`（M1）
- `PluginDao`：四张表的读写，所有方法带 `pluginId`；M1 用到登记与启停相关方法。

#### NEW: `lib/desktop/widgets/settings/settings_plugins_section.dart`（M1）
- 桌面设置对话框的插件 section，包装共用页面内容。

#### `lib/desktop/widgets/settings/settings_dialog.dart`（M1）
- 新增 `plugins` 导航项，排在 `mcp` 之后。

#### NEW: `lib/shared/widgets/settings/plugins/section.dart`（M1）
- 插件列表、状态、开关和详情；M2 增加安装、配置、权限、更新与卸载。

#### `lib/mobile/pages/settings_page.dart`（M1）
- 新增插件导航项，进入共用页面内容。

#### i18n（M1、M2）
- 新增 `settings.plugins*` 系列 key，加到 `assets/translations/en/settings.json`、`assets/translations/zh-CN/settings.json` 及 `lib/shared/localization/locale_keys.dart`。

#### NEW: `lib/shared/services/plugins/installer.dart`（M2）
- `PluginInstallOrchestrator`：zip 校验、解压、权限比较、目录移动与登记事务。

#### `lib/shared/services/backup_service.dart`（M2）
- `_backupEntries` 增加 `plugins`。

## 插件私有 SQLite

M3 的记忆插件使用真正的 SQLite 私有库。每个声明 `database` 的插件只有一个库，Host 按运行时插件身份选择，插件不能传文件路径或打开其他库。它是基础持久化能力，安装页说明会保存本地数据，不另弹创建数据库授权；宿主作品和聊天数据仍走业务权限 API。

库文件位于应用数据目录的 `plugin_data/<plugin_id>/data.sqlite`，与 `plugins/<id>/<version>/` 包目录分离。工具、Prompt 提供方、定时任务和 TSX 页面共用该库；连接、事务、排队、迁移、关闭和备份由 Dart 服务统一管理，SQL 在后台执行，不阻塞 Flutter UI。fjs 的 Rust 层只传递数据库调用，不另建 Rust 数据库服务。

### JS API

```ts
type SqlValue = null | string | number | bigint | Uint8Array;
type SqlRow = Record<string, SqlValue>;
interface SqlStatement {
  sql: string;
  params?: SqlValue[];
}
interface SqlWriteResult {
  changes: number;
  lastInsertRowId: bigint | null;
}
interface PluginSqlite {
  query(statement: SqlStatement): Promise<SqlRow[]>;
  execute(statement: SqlStatement): Promise<SqlWriteResult>;
  transaction(statements: SqlStatement[]): Promise<SqlWriteResult[]>;
}
```

通过处理函数上下文的 `sqlite` 使用（Prompt 提供方只有 `sqlite.query`）；未声明数据库时调用返回 `database_not_declared`。`apply` 收到的 `setup` 没有 `sqlite`，不能查询或写库。

- `query` 只接受单条只读查询，返回对象数组，没有行返回 `[]`；重复列名须用 SQL alias 消除，否则拒绝返回以免覆盖字段。
- `execute` 执行单条写入；`transaction` 按顺序执行写入数组，Host 在同一事务内全部成功才提交，失败全部回滚。空数组返回 `[]`。不提供 JS 事务回调或 `begin/commit/rollback`，不跨 AI 请求、网络请求或用户交互持有事务。
- 每条语句只允许一个 SQL statement，参数只使用位置绑定。插件可以使用 SQL 筛选、排序、联结、分页和索引。普通调用不能执行 DDL，建表、建索引和结构升级走包内 migration。
- 结果 `changes` 是当前语句影响行数；零行不是 SQL 错误，也不会自动回滚事务。乐观锁通过 `WHERE id = ? AND revision = ?` 和 `changes` 检查；需要失败即回滚的业务批次必须使用能在单条 SQL 中表达的条件或另行扩展契约，不假定事务数组有业务断言能力。
- `lastInsertRowId` 仅在该语句实际插入 rowid 表记录时返回值，其他情况为 null，不返回上次 INSERT 留下的连接值。
- `number` 只接受有限浮点数及安全整数；64 位整数用 `bigint`，超出 SQLite 有符号 64 位范围拒绝。返回 INTEGER 时安全范围内用 number，其余用 bigint。BLOB 使用 `Uint8Array`；SDK 在 JSON 桥中使用类型标签编码整数和二进制，业务 JS 不手写编码。工具结果和 Prompt 仍须转换成各自的 JSON / 文本契约。
- 每个插件的数据库操作由 Host 串行队列执行，单个事务不与其他调用交错；JS 的“先查后改”不自动形成事务。页面只丢弃迟到的展示结果，不能假定 Promise 取消就撤销已经提交的写入。
- 初始限额：单请求及结果各 1 MB、单查询最多 1000 行、单事务最多 100 条语句；请求等待预算 5 秒；单插件库正文最多 64 MB。结果超限直接报错，不静默截断；分页由插件显式使用 LIMIT。每插件最多 32 个待完成数据库调用，超限拒绝新调用；正文通过 max_page_count 限制，临时空间只监测并在下一次调用前拒绝继续增长，不声称恶意查询有严格磁盘或时间上限。
- 首版按可信插件设计。Host 固定私有库位置，SDK 不提供其他路径、连接或原生扩展入口；SQL 契约不支持 ATTACH/DETACH、PRAGMA、显式事务控制或文件函数。语句类型与 schema 校验用于发现误用，不宣称可以阻止任意恶意 SQL 访问进程资源，不增加 authorizer/progress handler、驱动补丁或原生中断桥。
- 业务数据默认软删除；普通运行时不开放 DELETE、DROP 或 REPLACE 等隐式删除路径，删除记忆使用 `UPDATE deleted_at`。物理清理需另行明确授权，不能从“允许 SQL”推导出通用硬删除权限。
- 失败返回 `PluginHostError`，保留 SQLite 主错误码、扩展错误码、实际消息、事务内失败语句下标；不把绑定值写进普通日志。额度、取消、权限和迁移错误分别使用可区分的 Host 错误码；UI 另转为可理解的文案。

### 插件 schema 与更新

清单声明数据库版本和完整迁移序列，版本从 1 开始连续递增，文件相对插件包：

```json
{
  "database": {
    "version": 1,
    "migrations": [{ "version": 1, "source": "migrations/001.sql" }]
  }
}
```

Host 在插件运行前执行迁移；首次创建库执行全部版本，已有库只执行缺少的版本。Host 记录版本与每份迁移的内容指纹，已执行迁移被修改、缺版本或降级均拒绝加载；版本与迁移记录由 Host 管理，插件 SQL 不能改写。未声明 database 的插件不创建空库。

首版结构只允许列、索引、主键及时间戳、软删除字段；不开放外键、CHECK、触发器、视图、FTS、生成列或原生扩展。插件自己的字段组合规则写在插件逻辑中，Host 仍校验存储边界。迁移允许建表、加列、建索引和保留数据的回填；不在升级时静默删除表、记录或改写已执行迁移。

安装更新对私有库使用一致性副本：先停止新调用、确认并关闭页面、等待已开始的工具/任务完成或取消并确认事务结束，再取得副本；在副本执行迁移与新版本激活校验，成功后才切换包版本与库。Host 保存可恢复的安装事务记录，覆盖“库切换成功、登记尚未提交”等崩溃窗口；恢复时先完成或撤销切换，再允许插件调用。失败保留原库和原包，不以空库重建或降级打开代替恢复。无私有库插件沿用前述安装流程。

插件自身 schema version 与应用主库 schemaVersion 独立。不得为第三方每次增加字段都修改主库 Drift schema，也不通过任意 SQL 访问旧的宿主 memories 表。

### 备份、停用与卸载

应用备份同时包含插件包、主库登记和 `plugin_data` 中各插件库的一致性快照；不能只复制正在写入的主文件而遗漏 WAL。恢复先恢复包和数据的对应版本，再按迁移契约打开，验证计数与内容。停用拒绝新调用、取消调度并释放空闲连接，数据保留；卸载也保留私有库，重新安装同一插件 ID 后复用。用户明确清除某插件数据时才删除该库，不能复用旧包目录清理逻辑。

### Dart 实施规格

- 驱动使用项目已锁定的 `sqlite3 3.7.0`，直接管理动态 SQL；不为每个插件生成 Drift DAO，不改驱动源码或 native assets。应用主库继续使用 Drift。语句分类使用已锁定的 `sqlparser 0.45.0`，实施时从传递依赖提升为显式依赖并保持版本，不新增 SQL 解析器。
- 落点为 `lib/shared/services/plugins/sqlite.dart`（Host API、身份与队列）、`sqlite_worker.dart`（后台 isolate、连接与 SQL）、`database_install.dart`（库迁移与安装协调）。这些是计划文件，本次不创建实现。
- 每个打开的插件库一个后台 isolate、一条连接；连接初始化由 Host 设置 journal_mode=DELETE、busy_timeout=1000、max_page_count（按 64 MB 换算），插件不能自行改这些参数；Host 按 pluginId 复用，空闲 60 秒且无引用/操作时关闭。主 isolate 只传 `{requestId, operation, statement(s), deadline}` 与绑定参数，不传连接指针。查询在 worker 用 `prepare(sql, checkNoTail: true)` 检查单语句，以 `isReadOnly` 检查 query；逐行读取并累计行数/编码字节，超限结束读取并报错，finally 关闭 statement。
- sqlparser 仅接受 query 的 SELECT（含 WITH）与 execute/transaction 的 INSERT、UPDATE；拒绝 REPLACE、INSERT OR REPLACE、ON CONFLICT DO UPDATE、RETURNING、DELETE 及其他语句类型。这是首版软删除契约，不能当作敌对代码沙箱。migration 独立允许 CREATE TABLE、ALTER TABLE ADD COLUMN、CREATE INDEX、INSERT/UPDATE 回填，并按前文结构范围检查 AST。
- 绑定参数中 int64 与 bigint 使用十进制标签，BLOB 使用 base64 标签。查询列名必须唯一；按 SQLite 单元格类型区分 INTEGER/REAL，不能把整数精度损失之后的 double 转回 bigint。changes 取 `updatedRows`；AST 是 INSERT 且实际插入行时取 `lastInsertRowId`，UPDATE 或零行插入返回 null。
- transaction 由 worker 执行 `BEGIN IMMEDIATE`，逐条 prepare/bind/execute，成功 COMMIT、异常 ROLLBACK；结果数组在提交后统一返回。runtime 销毁不直接关闭仍在执行 SQL 的连接。
- 队列中尚未开始的调用可以取消。已经进入同步 SQLite 调用时，Dart 的 Future 超时仅结束调用方等待，不能抢占 SQL；该 worker 继续到完成。写入返回 `commit_unknown`，查询返回 `wait_timeout`，Host 保留操作直到真实完成并记录最终状态；不杀 isolate、不重开同库第二条连接、不自动重试写入。长查询不阻塞 UI，但会阻塞该插件库，关闭/更新/备份等待它退出。
- Prompt 的 500 ms、任务和页面取消预算约束等待与后续阶段，不承诺立刻停止已开始的 SQL。其迟到结果不注入 Prompt 或恢复已关闭页面；已进入 SQLite 的写入仍可能提交。

### 安装切换的恢复步骤

仅处理插件包与插件私有库，不能修改主库业务表。实现复用现有安装编排与 `app_states` 保存 Host 安装记录，不新增通用分布式事务框架。

1. 暂停该插件的新工具、Prompt、任务和数据库调用，确认页面关闭，等待已开始的数据库操作结束。超时中止安装等待，保留原版本，不强杀数据库连接。
2. 对原库使用 `Database.backup(stagedDb).drain()` 取得一致性副本；首次安装创建空 staged 库。在副本单事务内执行缺失 migration 和 Host 迁移记录更新，再用仅注册权限的新运行时检查 apply。失败删除本次临时副本，原库和登记不动。
3. 关闭原库与副本连接；在主库 app_states 写入 `plugin_install.<id>`，记录 old/new version、固定的相对 staging/backup 路径、阶段 prepared。先把原 data.sqlite 重命名为本次 backup，再把 staged 文件改为 data.sqlite；连接关闭后才改名，Windows 不替换仍打开的文件。
4. 在主库同一事务内更新插件版本、授权与安装阶段为 committed。此前不允许任何新插件调用。主库提交失败按记录恢复 backup；恢复失败保持插件不可用并报错，不启用半切换状态。
5. 启动时先处理安装记录：prepared 恢复原版本及原库；committed 校验新文件存在后完成清理并允许激活。崩溃在两次改名中间时，按 backup/data/staged 的存在情况恢复；缺文件报错，禁止自动造空库。只删除本次更新产生且已有已提交替代品的副本，保留其他插件数据。

日常备份也使用驱动 backup API；不用直接复制带活动 WAL 的数据库。迁移账本保存在私有库的 Host 保留表 `_reveric_migrations(version, hash, applied_at)`，普通插件 SQL 不得引用；这是可信插件契约，不把表名前缀描述成安全隔离。
