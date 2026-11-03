// 职责: 在独立弹窗中打开首页管理页，关闭前询问页内未保存的草稿。
// 关联文件:
//   lib/desktop/widgets/agent_management/ai_providers_page.dart
//   lib/desktop/widgets/agent_management/ai_assistant_page.dart
//   lib/desktop/widgets/agent_management/mcp_page.dart
//   lib/shared/widgets/settings/leave_guard.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../../shared/components/dialog_feedback.dart';
import '../../../shared/components/reveric_dialog.dart';
import '../../../shared/components/reveric_icon_button.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/settings/leave_guard.dart';

/// 首页之外的入口（如「去配置供应商」）就地打开同一管理页，不离开当前上下文。
Future<void> showManagementPageDialog(
  BuildContext context, {
  required Widget Function(GlobalKey headerKey, Widget closeButton) builder,
}) {
  return showRevericDialog<void>(
    context: context,
    builder: (_) => _ManagementPageDialog(builder: builder),
  );
}

class _ManagementPageDialog extends HookWidget {
  const _ManagementPageDialog({required this.builder});

  final Widget Function(GlobalKey headerKey, Widget closeButton) builder;

  @override
  Widget build(BuildContext context) {
    final leave = useMemoized(SettingsLeaveController.new);
    final headerKey = useMemoized(GlobalKey.new);

    Future<void> close() async {
      if (await leave.confirmLeave() && context.mounted) {
        Navigator.of(context).pop();
      }
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) {
          return;
        }
        await close();
      },
      child: Dialog(
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 880,
          height: 640,
          child: SettingsLeaveScope(
            controller: leave,
            child: DialogFeedback(
              builder: (context) => builder(
                headerKey,
                RevericIconButton(
                  icon: RevericIcons.close,
                  tooltip: context.t(LocaleKeys.commonClose),
                  onPressed: close,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
