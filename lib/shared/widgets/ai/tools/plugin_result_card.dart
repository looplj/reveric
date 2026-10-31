// 职责: 用当前插件版本的只读 A2UI 模板展示工具结果，模板不可用时保留通用卡片。
// 关联文件:
//   lib/shared/widgets/ai/tools/plugin_tool_card_body.dart
//   lib/shared/widgets/a2ui/session.dart
//   lib/shared/widgets/a2ui/surface_view.dart
//   lib/shared/providers/plugin_providers.dart
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../logger/app_logger.dart';
import '../../../models/ai_message_block.dart';
import '../../../providers/plugin_providers.dart';
import '../../a2ui/session.dart';
import '../../a2ui/surface_view.dart';

final _log = AppLogger.forModule('PluginCard');

class PluginResultCard extends HookConsumerWidget {
  const PluginResultCard({
    super.key,
    required this.block,
    required this.fallback,
  });
  final AiToolCallBlock block;
  final Widget fallback;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(pluginStatusesProvider);
    final host = ref.read(pluginHostServiceProvider);
    final id = block.metadata?['plugin_id'];
    final status = host.statuses.where((s) => s.id == id).firstOrNull;
    final future = useMemoized(
      () async {
        if (id is! String ||
            block.result == null ||
            block.result?['ok'] == false) {
          return null;
        }
        try {
          return await host.readToolCard(id, block.toolName);
        } catch (error, stack) {
          _log.error(
            'Card template unavailable plugin=$id tool=${block.toolName}',
            error: error,
            stackTrace: stack,
          );
          return null;
        }
      },
      [
        host,
        id,
        block.toolName,
        block.result,
        status?.state,
        status?.manifest?.version,
      ],
    );
    final messages = useFuture(future).data;
    final session = useMemoized(() {
      if (messages == null) {
        return null;
      }
      final session = A2uiSurfaceSession.load(
        surfaceId: 'card-${identityHashCode(block)}',
        messages: messages,
      );
      if (session.error.value != null) {
        return session;
      }
      try {
        session.applyDataUpdates([
          A2uiDataUpdate(path: '/', value: block.result),
        ]);
      } catch (error, stack) {
        _log.error('Card result rejected', error: error, stackTrace: stack);
        session.dispose();
        return null;
      }
      return session;
    }, [messages, block.result]);
    useEffect(
      () => () {
        if (session != null) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => session.dispose(),
          );
        }
      },
      [session],
    );
    if (session == null ||
        session.error.value != null ||
        status?.state != 'available') {
      return fallback;
    }
    return ExcludeFocus(
      child: AbsorbPointer(child: A2uiSurfaceView(session: session)),
    );
  }
}
