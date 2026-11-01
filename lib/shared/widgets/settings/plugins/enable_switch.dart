// 职责: 插件启停开关 — 持久化启停选择，必填配置缺失时转交调用方引导填写。
// 关联文件:
//   lib/shared/widgets/settings/plugins/row.dart
//   lib/shared/widgets/settings/plugins/detail_page.dart
//   lib/shared/services/plugins/host.dart
//   lib/shared/providers/plugin_providers.dart
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../components/reveric_switch.dart';
import '../../../logger/app_logger.dart';
import '../../../providers/plugin_providers.dart';
import '../../../services/plugins/host.dart';
import '../../../services/plugins/runtime.dart';

final _log = AppLogger.forModule('Plugin');

class PluginEnableSwitch extends HookConsumerWidget {
  const PluginEnableSwitch({
    super.key,
    required this.status,
    required this.semanticLabel,
    required this.onNeedsConfig,
    required this.onSaveFailed,
  });

  final PluginStatus status;
  final String semanticLabel;

  /// 想开启但必填配置未填写；不会写入启停状态。
  final VoidCallback onNeedsConfig;

  /// 启停写入失败；参数为 false 表示新的写入已开始，可清除失败提示。
  final ValueChanged<bool> onSaveFailed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = useState(false);
    final host = ref.watch(pluginHostServiceProvider);
    Future<void> toggle(bool value) async {
      if (busy.value) {
        return;
      }
      if (value && status.needsConfig) {
        onNeedsConfig();
        return;
      }
      busy.value = true;
      onSaveFailed(false);
      try {
        await host.setEnabled(status.id, value);
      } catch (error, stack) {
        if (error is PluginHostError && error.code == 'cancelled') {
          return;
        }
        _log.error(
          'Enable preference failed: ${status.id}',
          error: error,
          stackTrace: stack,
        );
        if (context.mounted) {
          onSaveFailed(true);
        }
      } finally {
        if (context.mounted) {
          busy.value = false;
        }
      }
    }

    return Semantics(
      label: semanticLabel,
      child: RevericSwitch(
        key: ValueKey('plugin-toggle-${status.id}'),
        value: status.enabled,
        onChanged: busy.value || status.manifest == null ? null : toggle,
      ),
    );
  }
}
