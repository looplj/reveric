---
name: git
description: "Git 提交与历史操作规范。用于创建或修改 commit message、关联和关闭 issue，以及 rebase、merge 与 DB migration 版本冲突处理。"
---

# Git 规范

## Commit message

### 写什么

- 先看 `git diff --cached` 和近期提交，按实际暂存内容写消息；不要只复述用户请求，也不要将未暂存的改动写进提交。
- 标题沿用仓库的 `type(scope): summary` 风格，scope 可省略。常用 type 为 `fix`、`feat`、`refactor`、`test`、`docs`、`chore`；按改动目的选择，不把行为修复写成 refactor。语言跟随用户要求或近期提交。
- 标题说明具体行为变化，如 `fix: keep tool results together before sending images`，避免 `fix bug`、`update code` 等无信息标题。
- 简单改动只需标题。需要正文时，空一行后说明触发条件、根因和修复后的行为；只保留有助于理解改动的取舍和验证结果，不罗列文件名或排查过程。
- 验证只写实际执行的结果，区分测试、真实接口和真机验证；不能把 mock 测试写成接口验证，也不能把 macOS 上的路径测试写成 Windows 真机验证。

### Issue 引用不能漏

- 任务来自 issue 时，提交前回看该 issue 的仓库、编号和解决范围。已完整解决且用户没有要求保持打开时，在消息末尾单独一行写 `Fixes #123`；不要等用户提醒才补。
- 部分修复、仅诊断或只补测试时，使用 `Refs #123` 并说明尚未解决的部分，不提前关闭整个 issue。没有关联 issue 时不添加引用。
- 跨仓库引用写 `Fixes owner/repo#123`；关闭多个 issue 时逐条写完整引用，避免仓库或编号歧义。
- GitHub 在包含关闭引用的提交进入远端默认分支后才自动关闭 issue。本地 commit、amend 或推送到非默认分支，不代表 issue 已关闭。不要假定默认分支名；报告关闭状态前实际核对。
- 用户只要求 commit 时，不因此擅自 push、merge、发表评论或调用 `gh issue close`。补充关闭引用和直接修改 issue 状态是不同操作。

参考：[GitHub 官方的 issue 关闭引用规则](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/linking-a-pull-request-to-an-issue)。

完整修复的消息示例（编号替换为实际 issue）：

```text
fix: keep tool results together before sending images

Image messages interrupted parallel tool results and caused the provider
to reject subsequent requests. Defer images until the full batch is emitted.

Verified the rejected and accepted layouts against the provider API,
and added request serialization regression tests.

Fixes #123
```

### 写入和补漏

- 多行消息优先写入临时文件，用 `git commit -F` 读取，保留真实换行；避免 shell 插值改变反引号、变量或正文。
- 提交后用 `git log -1 --format=%B` 核对标题、正文和 issue 引用，并检查工作区状态。汇报提交 hash 和是否已推送，不将本地提交描述成已发布或已关闭 issue。
- 补写消息前核对当前 HEAD 和远端状态。确认是本任务的最新、未推送提交，且修订已获授权时，可 amend；不要顺带收入新暂存内容。已推送的提交不为补一句引用自行重写历史或 force push，按用户已授权的 PR／issue 流程补充关联。

## Rebase 冲突处理规则

- 解决 git rebase 冲突时，禁止执行 `git rebase --continue`。因为该命令会打开交互式编辑器，而非交互式环境无法处理。
- 冲突解决后应报告给用户，由用户手动执行 `git rebase --continue` 操作。

## Rebase 冲突的内容取舍判据

rebase 把旧提交叠到新基之上，方向与 merge 相反，冲突双方含义也相反：

- `<<<<<<< HEAD` = **新基**（要叠上去的底）
- `>>>>>>> <commit>` = **自己的旧提交**（被回放者）

取舍判据不是「哪边更新取哪边」，而是「新基的决定是基准，旧提交只能增量」：

- 旧提交**纯新增**了新基没有的内容 -> 保留
- 旧提交把新基已删除 / 迁移 / 重命名的内容又带回来 -> 丢弃（不得复活新基已删除的内容）

「旧提交更完整」可能是把新基刻意删掉的东西补了回来，不是合并收益。先 `git show <new-base>:<file>` 看新基对该区域的实际动作（删除 / 搬迁 / 未触碰），再决定取舍。

## Rebase 中的 DB Migration 版本冲突解决

在 rebase 过程中，两个分支可能同时添加了同一个 schema 版本号（如双方都写了 `migrateToV13`），导致冲突。

### 识别冲突

冲突表现为以下之一：
- `app_database_migrations.dart` 中出现两个同名 `migrateToV{n}` 方法
- `app_database.dart` 的 `schemaVersion` 数值冲突
- `onUpgrade` 调用链中两个分支对同一版本号做了不同的事

### 解决原则

1. **保留 base（上游分支）的版本号**。被 rebase 到的目标分支（通常是 `development` / `master`）的迁移版本号保持不变。
2. **feature 分支的 schema 改动移到下一个可用版本号**。将冲突的 `migrateToV{n}` 重命名为 `migrateToV{n+1}`，同步更新：
   - `schemaVersion`（提升到 `n+1`）
   - `onUpgrade` 中添加对应版本的调用：`if (from < n+1) { await migrations.migrateToV{n+1}(migrator); }`

### 原因

base 分支（上游分支）的 schema 已在发布或已部署的数据库中生效。改变 base 的版本号会破坏已有用户的数据库升级路径。feature 分支尚未发布，其 schema 变更可以延后到下一个版本号。

### 操作步骤

1. 定位冲突的 `migrateToV{n}` 方法
2. 保留 base 版本，将 feature 版本重命名为 `migrateToV{n+1}`（更新注释和方法名）
3. 在 `app_database.dart` 中将 `schemaVersion` 更新为 `n+1`
4. 在 `onUpgrade` 中添加调用：`if (from < n+1) { await migrations.migrateToV{n+1}(migrator); }`
5. 检查 migration 测试是否引用 `schemaVersion`（通常用 `db.schemaVersion` 动态获取，无需改动）
6. Stage 修改：`git add <files>`
7. 报告用户手动执行 `git rebase --continue`
