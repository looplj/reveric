# 数据库 migration 规则

## Schema 结构边界

- **数据库默认只用列和索引**：新增或修改 schema 时，默认可用的结构只有列（类型、可空、默认值）、索引、Drift 的 `primaryKey` 声明，以及项目既有的时间戳与软删除列写法。其余 SQLite / Drift 特性一律默认不用：CHECK、表级 `customConstraints`、表级 UNIQUE、FOREIGN KEY 及其级联行为、触发器、视图、生成列、虚拟表与 FTS、AUTOINCREMENT、自定义 collation。确有必要时，先说明为什么 Dart 侧校验不够、改动代价与迁移方案，获得用户明确确认后再写。
  - 理由是它们改不动：SQLite 没有 `ALTER TABLE ... DROP/ADD CONSTRAINT`。CHECK 里多一个枚举取值、外键换一种级联行为，都要走「建新表 → 复制数据 → 删旧表 → 改名」重建整表并在迁移里重放；列和索引可以 `ADD COLUMN` / `CREATE INDEX` 原地完成。
  - 取值范围、必填组合、跨字段互斥这类规则写在 Dart 侧：模型校验、service 校验和静态 tool schema。同一条规则不要 SQL 和 Dart 各写一遍。
  - 已有的约束保持原样，不顺手补齐也不顺手删除；要改按上面的确认流程走。

## 发布状态与版本策略

发布状态按 `AGENTS.md`「发布状态只核对最新正式发布 tag」核查，不能根据源码注释、当前分支或 `pubspec.yaml` 的版本号推断。

- **未发布版本的 migration 合并**：经本地最新正式发布 tag 及其对应代码核实，确认当前 schema 尚未发布时，新增字段可以合并进现有 migration，保持 `schemaVersion` 不变；不要为本地开发库额外添加运行时幂等补列、fallback 或兼容层。直接用 SQLite skill 的 `ALTER TABLE ... ADD COLUMN` 手动升级开发数据库，并查询验证结果。已发布的 schema 必须新增 schema version 和正式 migration，不能追加到旧 migration 代替用户升级。

- 向已正式发布的 Drift schema 添加字段时，必须同时做三件事：
  1. 在 `lib/shared/database/novel_content_database.dart`（或对应 database 文件）中提升 `schemaVersion`（当前值加 1）
  2. 在 `onUpgrade` 回调中添加对应版本号的 migration 步骤，使用 `migrator.addColumn(table, table.newColumn)` 或 `customStatement` 执行 `ALTER TABLE`
  3. 在该表对应的 `@DataClass` 或模型 Dart 类中添加新字段
- 已发布 schema 的修改不满足以上三点时**禁止合入**。只改 Dart 表定义不改版本号和 migration，会导致已有数据库静默不生效，新列根本不存在，写入无报错但数据丢失。
- 开发过程中如果已部署的数据库与当前 schemaVersion 不一致，可用 `PRAGMA user_version` 确认数据库当前版本。

## 历史表重建与当前 schema

以下规则用于正式升级路径中已有的历史表重建；不得用于为未发布 schema 的本地开发库增加运行时兼容层。

- Drift 的历史 migration 会使用当前生成的表定义。给表新增字段后，旧版本中的裸 `TableMigration(table)` 也会把该字段加入 copy SQL；如果旧表没有该列，跨版本升级可能直接失败，或在启用 SQLite 双引号字符串兼容时把列名文本写入数据。
- 给已有表新增、重命名或删除字段时，必须搜索该表的全部历史 `TableMigration`，以及手写的 rename/create/copy 表重建。逐个核对对应源版本实际拥有的列，禁止假设只执行最新 migration 就足够。
- 表重建的目标字段在源版本中不存在时，必须在 `TableMigration` 中同时通过 `newColumns` 声明，并用 `columnTransformer` 为已有行提供明确值；也可以在重建前先以幂等方式补列。非空字段不得依赖 SQLite 隐式行为或双引号字符串兼容。
- 历史 migration 需要兼容 schema 漂移：在把字段视为新增前先检查实际列是否存在；已存在时必须保留原值，缺失时才执行补列或默认值转换。
- 手写表重建必须在 `INSERT ... SELECT` 两侧显式列出字段；目标表中未参与复制的字段必须可空、有数据库默认值或显式回填，禁止依赖当前 `createTable` 生成结果碰巧兼容旧行。

## 发布升级回归

- 每次数据库变更必须测试从所有仍受支持的正式发布 schema 直接升级到当前 schema，不能只测相邻版本。至少覆盖上一正式版、受影响表最近一次重建前的正式版，以及本次字段变更前的正式版。
- migration 测试必须使用旧版真实结构的 SQLite fixture，并至少断言：最终 `user_version`、主键/索引等结构、旧记录数量与关键字段值、以及新增字段的 SQLite 类型和值。只断言“打开成功”或“列存在”不足以防止数据污染。
- 对 Drift 表执行重建后，必须通过对应 Typed DAO 读取至少一条迁移记录。这样可捕获 SQLite 将缺失的双引号标识符当成文本后，结构检查仍通过的假绿灯。
