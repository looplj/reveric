// 职责: 检查地图生成所需的模型和地点，展示单图生成操作或引导配置图片模型。
// 关联文件:
//   lib/shared/providers/map_studio_providers.dart
//   lib/desktop/features/map/map_cartographer_panel.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/map_editor.json
//   assets/translations/zh-CN/map_editor.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/state-management.md
//   .agents/rules/i18n.md
//   .agents/rules/icons.md

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../theme/theme.dart';
import '../../providers/map_studio_providers.dart'
    show mapStudioControllerProvider, mapDraftImageModelSelectionProvider;

/// 展示单图生成按钮；进度由主画布统一展示。
///
/// 桌面挂在制图师面板底部；判定逻辑只有这一份。
class MapGenerateFooter extends ConsumerWidget {
  const MapGenerateFooter({
    super.key,
    required this.databasePath,
    required this.mapId,
    required this.onGenerate,
    required this.onConfigureImageModel,
    required this.hasChildLocations,
    this.hasPendingAgentDraft = false,
    this.showGateTooltip = true,
    this.modelId,
  });

  /// 内容库路径；[MapStudioController] 以 (databasePath, mapId) 为 family 键。
  final String databasePath;

  /// 由面板按当前画风/尺寸/质量/参考开关拼出的预估键；任一变化即重新预估。
  final String mapId;
  final String? modelId;
  final VoidCallback onGenerate;

  /// 未配置图片模型时，按钮改为打开各端的模型设置。
  final VoidCallback onConfigureImageModel;
  final bool hasChildLocations;
  final bool hasPendingAgentDraft;

  /// 被门禁挡住时是否用 hover tooltip 说明原因。触屏没有 hover，移动端传 false。
  final bool showGateTooltip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final isBusy = ref.watch(
      mapStudioControllerProvider(
        databasePath,
        mapId,
      ).select((state) => state.isBusy),
    );
    if (isBusy) {
      return const SizedBox.shrink();
    }

    final imageSelection = ref.watch(
      mapDraftImageModelSelectionProvider(modelId),
    );
    // 缺图片模型是环境前提，先于地点门禁处理：按钮直接改为去配置。
    final needsImageModel = !hasPendingAgentDraft && imageSelection == null;
    final generateBlocked = hasPendingAgentDraft || !hasChildLocations;
    final blockedMessageKey = hasPendingAgentDraft
        ? LocaleKeys.mapEditorAgentDraftResolveFirst
        : !needsImageModel && !hasChildLocations
        ? LocaleKeys.mapEditorStudioNeedsLocations
        : null;
    final tooltip = !showGateTooltip || blockedMessageKey == null
        ? null
        : context.t(blockedMessageKey);
    final generateButton = SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: needsImageModel
            ? onConfigureImageModel
            : generateBlocked
            ? null
            : onGenerate,
        icon: RevericIcon(
          needsImageModel
              ? RevericIcons.settings_outlined
              : RevericIcons.auto_awesome,
          size: 16,
        ),
        label: Text(
          context.t(
            needsImageModel
                ? LocaleKeys.aiConfigureImageModel
                : LocaleKeys.mapEditorStudioGenerate,
          ),
        ),
      ),
    );
    final generateControl = tooltip == null || tooltip.isEmpty
        ? generateButton
        : Tooltip(
            message: tooltip,
            waitDuration: const Duration(milliseconds: 300),
            child: Listener(
              behavior: HitTestBehavior.opaque,
              child: generateButton,
            ),
          );

    return Column(
      children: [
        generateControl,
        const SizedBox(height: RevericSpacing.xs),
        Text(
          context.t(
            hasPendingAgentDraft
                ? LocaleKeys.mapEditorAgentDraftResolveFirst
                // 触屏没有 tooltip：按钮被拦下的原因改写在这一行。
                : !showGateTooltip && blockedMessageKey != null
                ? blockedMessageKey
                : LocaleKeys.mapEditorAiGeneratedNotice,
          ),
          textAlign: TextAlign.center,
          style: typo.uiTiny.copyWith(color: colors.textSubtle),
        ),
      ],
    );
  }
}
