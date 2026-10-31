// 职责: 提供应用级插件宿主及供设置页订阅的运行状态。
// 关联文件:
//   lib/shared/services/plugins/host.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  ref.onDispose(host.dispose);
  return host;
});
final pluginStatusesProvider = StreamProvider<List<PluginStatus>>((ref) async* {
  final host = ref.watch(pluginHostServiceProvider);
  yield host.statuses;
  yield* host.changes;
});
