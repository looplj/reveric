// 职责: 提供应用级插件宿主及供设置页订阅的运行状态。
// 关联文件:
//   lib/shared/services/plugins/host.dart
import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/plugins/task_ai.dart';
import 'settings_providers.dart';
import 'usage_query_providers.dart';
import '../services/plugins/host.dart';
import '../services/plugins/data.dart';
import '../services/plugins/registry.dart';
import '../services/ai/tools.dart';
import '../services/ai/codemode/tool.dart';
import 'novel_providers.dart';

// 单个应用宿主跨设置页面与对话存活，运行时本身仍按调用创建和关闭。
final pluginHostServiceProvider = Provider<PluginHostService>((ref) {
  final host = PluginHostService(
    dao: ref.watch(appDatabaseProvider).pluginDao,
    taskAi: (request, cancellation) =>
        ref.read(pluginTaskAiServiceProvider).generate(request, cancellation),
    data: PluginDataService(
      database: ref.watch(appDatabaseProvider),
      services: (path) => (
        content: ref.read(novelContentServiceProvider(path)),
        overlay: ref.read(workingOverlayServiceProvider(path)),
      ),
    ),
    registry: PluginRegistry(
      hostToolNames: aiToolCatalog.map((tool) => tool.name).toSet()
        ..add(codemodeToolName),
    ),
  );
  final listener = AppLifecycleListener(
    onStateChange: (state) =>
        unawaited(host.setForeground(state == AppLifecycleState.resumed)),
  );
  final lifecycle = WidgetsBinding.instance.lifecycleState;
  if (lifecycle != null) {
    unawaited(host.setForeground(lifecycle == AppLifecycleState.resumed));
  }
  ref.onDispose(() {
    listener.dispose();
    unawaited(host.dispose());
  });
  return host;
});
final pluginStatusesProvider = StreamProvider<List<PluginStatus>>((ref) async* {
  final host = ref.watch(pluginHostServiceProvider);
  yield host.statuses;
  yield* host.changes;
});

final pluginTaskAiServiceProvider = Provider<PluginTaskAiService>(
  (ref) => PluginTaskAiService(
    settings: () => ref.read(aiSettingsProvider),
    usageService: ref.watch(usageServiceProvider),
  ),
);
