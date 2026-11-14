# 测试与验证规则

## 测试价值

- 测试不检查日志级别（如 DEBUG、INFO、WARN、ERROR）；诊断日志需要验证时，只检查必要的错误详情与关联信息，不把级别选择固定为测试契约。
- 测试必须验证业务意图，而不只是实现细节。测试失败应能捕获真实回归；只验证单个 `isLoading` 等平凡条件、不可能随业务逻辑变化而失败的测试不值得引入隔离成本。
- 修复 bug 时，回归测试应覆盖导致问题的输入、状态或生命周期边界，而不是只断言最终某个布尔值。

## 受影响目录验证

- 修改文件后，运行所涉及目录最窄且有意义的测试，再报告完成。
- 多个 `flutter test` 必须串行执行，禁止并行运行，避免 Flutter 测试环境冲突。
- 修改目录没有对应测试或当前环境无法运行时，必须说明原因，并给出最接近的 analyze、现有测试或手工验证；不得把未运行描述成通过。

## Widget 测试隔离

- `keepAlive` provider（如 `appSettingsDatabaseProvider`、`appDatabaseProvider`）会通过 `AppDatabase()` factory 复用静态 `_cachedDatabase`。`ref.onDispose(database.close)` 的异步关闭可能晚于 `ProviderScope` dispose，使下一个 `testWidgets` 取得脏状态。
- 多个 `testWidgets` 共用进程时，优先检查测试是否值得承担该隔离成本。不要为了平凡断言 override 一长串 provider。
- 确实需要多个 `testWidgets` 共存时，参考 `test/shared/widgets/md/markdown_block_editor_test.dart`：测试间使用 `pumpWidget(const SizedBox.shrink())` 清理 widget 树。
- 如果一个修复开始叠加 `appDatabaseProvider -> appSettingsDatabaseProvider -> novelReadingProgressProvider -> ...` 的 override 链，停止补丁叠加，重新检查根因和测试价值。

## 本地化资源的 Future 缓存隔离

使用 `EasyLocalization` + `MergingAssetLoader` 加载真实翻译资源的 widget 测试，必须在每个用例开始前清除资源缓存，即使文件当前只有一个用例：

```dart
// flutter/services.dart 提供 rootBundle。
setUp(() => rootBundle.clear());
```

原因：`rootBundle.loadString()` 缓存的是 `Future<String>`。每个 `testWidgets` 有独立的 FakeAsync 队列；后续用例 `await` 前一个用例已完成的缓存 Future 时，当前 SDK 会把唤醒续执行的微任务排入该 Future 所属的旧 Zone。当前用例的 `pump()` 只推进自己的队列，翻译加载无法完成，`Localizations` 返回空子树，表现为找不到 Widget 或 `Bad state: No element`。

- `EasyLocalization.ensureInitialized()` 初始化语言偏好，不能替代资源缓存隔离。重复初始化、增加 `pumpAndSettle()` 次数或只拆除 widget 树，都不能推进旧用例的队列。
- 自定义 loader 仅返回内存翻译、没有使用 `rootBundle` 缓存 Future 时，不套用此规则。不要为测试隔离修改生产 loader 的缓存策略，也不要靠拆分测试文件或合并多个 `testWidgets` 绕过问题。
- 出现「单跑通过、一起失败」时，先单跑失败用例，再与前一个加载翻译的用例一起跑；检查是否复用缓存 Future、加载停在哪一步，不能仅凭症状认定是 EasyLocalization 单例或 provider 污染。
- 验证只运行相关用例和所在文件；修复后必须整文件通过，不能只报告单个用例通过。参考 `test/shared/widgets/md/markdown_block_editor_test.dart`。

## drift stream 的 pending timer

被测子树**实际 watch 了 drift stream provider**（`@riverpod Stream<...>`，如 `imageBatchesProvider`、`imageBatchSlotsProvider`、`imageAssetsProvider`）时，每个 `testWidgets` 结尾都要拆树并 settle，与文件里有几个 `testWidgets` 无关：

```dart
await tester.pumpWidget(const SizedBox.shrink());
await tester.pumpAndSettle();
```

原因：`ProviderScope` dispose → riverpod dispose `StreamProvider` → drift 的 `QueryStream._onCancelOrPause` → `StreamQueryStore.markAsClosed` 排一个 0 延时 timer。测试体结束时 `_verifyInvariants` 发现它还挂着，直接判失败：

```
A Timer is still pending even after the widget tree was disposed.
'package:flutter_test/src/binding.dart': Failed assertion: line 2568 pos 12: '!timersPending'
```

只 `pumpWidget(SizedBox.shrink())` 不够 —— 那个 0 延时 timer 要靠 `pumpAndSettle()` 冲掉。

判断依据是**有没有 watch stream**，不是有没有 override `appDatabaseProvider`：同目录的 `canvas_test` / `designer_test` / `studio_page_test` 都 override 了 database 但不 watch stream，无需收尾；`records_back_test.dart` watch 了 `imageBatchesProvider`，必须收尾（参考实现在该文件）。

## 跑测试的操作纪律

- **不要把 `flutter test` 的输出 pipe 给 `grep`**。非 tty 下 grep 块缓冲，进程跑完前看不到任何一行，一个 1 秒就失败的测试会表现得像卡死。先 `> /tmp/xxx.log` 落完整日志，再过滤。
- **widget 测试一律带 `timeout`**。测试体失败后 flutter_tester 可能不退出（`tearDownAll` 卡在临时目录已被清的 `PathNotFoundException`），会空挂十分钟以上。
- **怀疑"跑得慢"时先看 CPU 时间**：`ps -eo pid,etime,time -p <pid>`。挂钟很长而 CPU 只有一两秒 = 在等某个永不完成的 future/timer，不是在算；继续等或加长 timeout 没有意义，直接杀掉查根因。
- 排查测试问题时不要 `git stash` 去对基线 —— 那会清空整个工作区。要对比就用 `git stash` 之外的手段（`git diff`、单独 checkout 到别处）。
