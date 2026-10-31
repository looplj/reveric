// 职责: 验证请求 Prompt 的独立并发队列、整块 token 预算、过期作用域丢弃及上下文快照的追加判定。
// 关联文件:
//   lib/shared/services/plugins/prompt.dart
//   lib/shared/models/plugin/request.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/shared/agent/message.dart';
import 'package:reveric/shared/models/plugin/request.dart';
import 'package:reveric/shared/services/plugins/prompt.dart';

const request = PluginRequestContext(
  requestId: 'request',
  sessionId: 'session',
  workId: null,
  agentId: 'test',
  mode: 'chat',
);
void main() {
  test(
    'at most two providers globally and one per plugin run independently',
    () async {
      final diagnostics = <PluginPromptDiagnostic>[];
      final collector = PluginPromptCollector(onDiagnostic: diagnostics.add);
      final active = <String, int>{};
      var peak = 0;
      PluginPromptSource source(String id) => PluginPromptSource(
        pluginId: id,
        providerId: 'p',
        current: () async => true,
        run: (budget, cancellation) async {
          active[id] = (active[id] ?? 0) + 1;
          expect(active[id], 1);
          final total = active.values.fold(0, (a, b) => a + b);
          if (total > peak) {
            peak = total;
          }
          expect(total, lessThanOrEqualTo(2));
          await Future<void>.delayed(const Duration(milliseconds: 20));
          active[id] = active[id]! - 1;
          return id;
        },
      );
      final results = await Future.wait([
        collector.collect(request, [source('a')]),
        collector.collect(request, [source('a')]),
        collector.collect(request, [source('b')]),
        collector.collect(request, [source('c')]),
      ]);
      expect(results.every((list) => list.single.text != null), true);
      expect(peak, 2);
      expect(diagnostics, isEmpty);
      await collector.dispose();
    },
  );
  test(
    'aggregate limits omit complete blocks and order sources deterministically',
    () async {
      final diagnostics = <PluginPromptDiagnostic>[];
      final collector = PluginPromptCollector(onDiagnostic: diagnostics.add);
      PluginPromptSource source(String id, String provider, String text) =>
          PluginPromptSource(
            pluginId: id,
            providerId: provider,
            current: () async => true,
            run: (_, _) async => text,
          );
      final result = await collector.collect(request, [
        source('c', 'p', '丙' * 800),
        source('b', 'p', '乙' * 800),
        source('a', 'z', '甲' * 600),
        source('a', 'a', '首' * 600),
      ]);
      expect(result.map((r) => '${r.pluginId}/${r.providerId}'), [
        'a/a',
        'b/p',
      ]);
      expect(diagnostics.map((d) => d.code), everyElement('prompt_budget'));
      expect(diagnostics, hasLength(2));
      await collector.dispose();
    },
  );
  test(
    'a source invalidated during preparation never contributes stale text',
    () async {
      final diagnostics = <PluginPromptDiagnostic>[];
      final collector = PluginPromptCollector(onDiagnostic: diagnostics.add);
      var current = true;
      final result = await collector.collect(request, [
        PluginPromptSource(
          pluginId: 'test',
          providerId: 'p',
          current: () async => current,
          run: (_, _) async {
            current = false;
            return 'stale';
          },
        ),
      ]);
      expect(result, isEmpty);
      expect(diagnostics, isEmpty);
      await collector.dispose();
    },
  );
  test(
    'context snapshot is compared with the last one of the same provider',
    () {
      const memory = PluginPromptResult(
        pluginId: 'a',
        providerId: 'memory',
        text: 'v1',
      );
      const other = PluginPromptResult(
        pluginId: 'b',
        providerId: 'memory',
        text: 'v1',
      );
      AgentMessage user(String content) =>
          AgentMessage.user(id: content.hashCode.toString(), content: content);
      final v1 = renderPluginContext(memory);
      final v2 = renderPluginContext(
        const PluginPromptResult(
          pluginId: 'a',
          providerId: 'memory',
          text: 'v2',
        ),
      );
      expect(pluginContextMessages(const [], const []), isEmpty);
      // 从未发过的空内容不追加。
      expect(
        pluginContextMessages(const [
          PluginPromptResult(pluginId: 'a', providerId: 'memory', text: null),
        ], const []),
        isEmpty,
      );
      final added = pluginContextMessages(const [memory, other], const []);
      expect(added.map((m) => m.content), [v1, renderPluginContext(other)]);
      expect(added.every((m) => m.role == AgentMessageRole.user), true);
      expect(
        pluginContextMessages(const [memory], [user(v1), user('chat')]),
        isEmpty,
      );
      expect(
        pluginContextMessages(
          const [memory],
          [user(v1), user(v2)],
        ).single.content,
        v1,
      );
      expect(
        AgentMessage.assistant(id: 'x', content: v1).role,
        AgentMessageRole.assistant,
      );
      expect(
        pluginContextMessages(
          const [memory],
          [AgentMessage.assistant(id: 'x', content: v1)],
        ),
        hasLength(1),
      );
      expect(
        pluginContextMessages(
          const [
            PluginPromptResult(pluginId: 'a', providerId: 'memory', text: null),
          ],
          [user(v1)],
        ).single.content,
        contains('{"content":null}'),
      );
    },
  );
}
