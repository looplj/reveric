// 职责: 移动端模型选择两级弹窗 — 支持清空模型，并为推理模型下钻选择推理强度。
// 关联文件:
//   lib/mobile/pages/novel_chat_page.dart
//   lib/mobile/pages/ai_providers_settings_page.dart
//   lib/shared/widgets/ai/provider_model_icon.dart
//   lib/shared/widgets/ai/reasoning_effort_bars.dart
//   lib/shared/models/ai_provider.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
//   assets/translations/en/mobile.json
//   assets/translations/zh-CN/mobile.json
// 遵循的 Rules:
//   .agents/rules/icons.md
//   .agents/rules/design-system.md
//   .agents/rules/i18n.md
import 'package:flutter/material.dart';

import '../pages/ai_providers_settings_page.dart';
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/models/ai_provider.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/ai/provider_model_icon.dart';
import '../../shared/widgets/ai/reasoning_effort_bars.dart';

/// 打开两级模型/推理强度选择弹窗。
///
/// 第一级：模型列表。非推理模型选中显示对勾；推理模型右侧显示当前 effort 药丸
/// （点击下钻第二级）。点模型行 = 选中该模型并关闭。
///
/// 第二级：该推理模型的推理强度列表（含 `none`「关闭」/ `on`「开启」等 toggle 档位，
/// 与桌面端一致）。点某档位 = 选中该模型 + 该 effort 并关闭。
///
/// [selectedEffort] 为当前会话已选 effort；某推理模型的展示档位经
/// [reasoningEffortForOption] 回落到默认档位（对齐桌面端 `_displayEffortFor`）。
/// [unsetLabel] 与 [onUnset] 同时提供时，模型列表首项允许清空选择。
Future<void> showAiModelEffortSheet(
  BuildContext context, {
  required String title,
  required String subtitle,
  required List<AiModelOption> models,
  required String? selectedId,
  required String? selectedEffort,
  required Set<String> disabledModelIds,

  required ValueChanged<AiModelOption> onSelectModel,
  required void Function(AiModelOption option, String effort) onSelectEffort,
  String? unsetLabel,
  VoidCallback? onUnset,
}) {
  final colors = RevericTheme.colorsOf(context);
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: colors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(RevericRadius.x2l),
      ),
    ),
    builder: (sheetContext) => _ModelEffortSheet(
      title: title,
      subtitle: subtitle,
      models: models,
      selectedId: selectedId,
      selectedEffort: selectedEffort,
      disabledModelIds: disabledModelIds,

      onSelectModel: onSelectModel,
      onSelectEffort: onSelectEffort,
      unsetLabel: unsetLabel,
      onUnset: onUnset,
    ),
  );
}

class _ModelEffortSheet extends StatefulWidget {
  const _ModelEffortSheet({
    required this.title,
    required this.subtitle,
    required this.models,
    required this.selectedId,
    required this.selectedEffort,
    required this.disabledModelIds,

    required this.onSelectModel,
    required this.onSelectEffort,
    this.unsetLabel,
    this.onUnset,
  });

  final String title;
  final String subtitle;
  final List<AiModelOption> models;
  final String? selectedId;
  final String? selectedEffort;
  final Set<String> disabledModelIds;
  final ValueChanged<AiModelOption> onSelectModel;
  final void Function(AiModelOption option, String effort) onSelectEffort;
  final String? unsetLabel;
  final VoidCallback? onUnset;

  @override
  State<_ModelEffortSheet> createState() => _ModelEffortSheetState();
}

class _ModelEffortSheetState extends State<_ModelEffortSheet> {
  /// 正在配置推理强度的模型；null = 停留在模型列表层。
  AiModelOption? _effortFor;

  /// 该模型当前展示的 effort：选中模型用会话 effort，其余用默认档位。
  String? _displayEffortOf(AiModelOption option) => reasoningEffortForOption(
    option,
    option.id == widget.selectedId ? widget.selectedEffort : null,
  );

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: _effortFor == null
            ? _buildModelList(context, colors)
            : _buildEffortList(context, colors, _effortFor!),
      ),
    );
  }

  // ── 第一级：模型列表 ──────────────────────────────────────────────
  Widget _buildModelList(BuildContext context, RevericColors colors) {
    final typo = RevericTheme.typographyOf(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SheetHeader(
          leading: _IconBox(
            icon: RevericIcons.psychology_outlined,
            colors: colors,
          ),
          title: widget.title,
          subtitle: widget.subtitle,
        ),

        Flexible(
          child: ListView.builder(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(
              RevericSpacing.sm,
              0,
              RevericSpacing.sm,
              RevericSpacing.md,
            ),
            itemCount:
                widget.models.length +
                (widget.unsetLabel != null && widget.onUnset != null ? 1 : 0),
            itemBuilder: (context, index) {
              final hasUnset =
                  widget.unsetLabel != null && widget.onUnset != null;
              if (hasUnset && index == 0) {
                return _UnsetModelRow(
                  label: widget.unsetLabel!,
                  selected:
                      widget.selectedId == null || widget.selectedId!.isEmpty,
                  colors: colors,
                  typo: typo,
                  onTap: () {
                    widget.onUnset!();
                    Navigator.of(context).pop();
                  },
                );
              }
              final option = widget.models[index - (hasUnset ? 1 : 0)];
              return _ModelRow(
                option: option,
                selected: option.id == widget.selectedId,
                disabled: widget.disabledModelIds.contains(option.id),

                displayEffort: _displayEffortOf(option),
                colors: colors,
                typo: typo,
                onSelect: () {
                  widget.onSelectModel(option);
                  Navigator.of(context).pop();
                },
                onOpenEffort: () => setState(() => _effortFor = option),
              );
            },
          ),
        ),
        Divider(height: 1, color: colors.border),
        InkWell(
          onTap: () {
            final navigator = Navigator.of(context);
            navigator.pop();
            navigator.push(
              MaterialPageRoute<void>(
                builder: (_) => const MobileAiProvidersSettingsPage(),
              ),
            );
          },
          child: SizedBox(
            height: 44,
            child: Center(
              child: Text(
                context.t(LocaleKeys.aiAddModel),
                style: typo.ui.copyWith(color: colors.textMuted),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── 第二级：推理强度 ──────────────────────────────────────────────
  Widget _buildEffortList(
    BuildContext context,
    RevericColors colors,
    AiModelOption option,
  ) {
    final typo = RevericTheme.typographyOf(context);
    final efforts = option.reasoningEfforts ?? const <String>[];
    final current = _displayEffortOf(option);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SheetHeader(
          leading: _BackButton(
            colors: colors,
            onTap: () => setState(() => _effortFor = null),
          ),
          title: context.t(LocaleKeys.aiReasoningEffort),
          subtitle: option.displayModelName,
        ),
        Flexible(
          child: ListView.builder(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(
              RevericSpacing.sm,
              0,
              RevericSpacing.sm,
              RevericSpacing.md,
            ),
            itemCount: efforts.length,
            itemBuilder: (context, index) {
              final effort = efforts[index];
              final on = effort == current;
              return InkWell(
                borderRadius: BorderRadius.circular(RevericRadius.large),
                onTap: () {
                  widget.onSelectEffort(option, effort);
                  Navigator.of(context).pop();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: RevericSpacing.md,
                    vertical: RevericSpacing.sm + 3,
                  ),
                  child: Row(
                    children: [
                      ReasoningEffortBars(total: efforts.length, level: index),
                      const SizedBox(width: RevericSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              reasoningEffortLabelOf(context, effort),
                              style: typo.body.copyWith(
                                color: on ? colors.accent : colors.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              reasoningEffortHintOf(context, effort),
                              style: typo.uiTiny.copyWith(
                                color: colors.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (on)
                        RevericIcon(
                          RevericIcons.check,
                          size: 18,
                          color: colors.accent,
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _UnsetModelRow extends StatelessWidget {
  const _UnsetModelRow({
    required this.label,
    required this.selected,
    required this.colors,
    required this.typo,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final RevericColors colors;
  final RevericTypography typo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(RevericRadius.large),
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: selected ? colors.selected : colors.surface,
          borderRadius: BorderRadius.circular(RevericRadius.large),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.md,
          vertical: RevericSpacing.lg,
        ),
        child: Row(
          children: [
            _IconBox(
              icon: RevericIcons.block_rounded,
              colors: colors,
              size: 32,
              iconSize: 16,
            ),
            const SizedBox(width: RevericSpacing.md),
            Expanded(
              child: Text(
                label,
                style: typo.uiMedium.copyWith(color: colors.textPrimary),
              ),
            ),
            if (selected)
              RevericIcon(RevericIcons.check, size: 18, color: colors.accent),
          ],
        ),
      ),
    );
  }
}

/// 弹窗顶部标题栏：leading（图标盒 / 返回键）+ 标题 + 副标题。
class _SheetHeader extends StatelessWidget {
  const _SheetHeader({
    required this.leading,
    required this.title,
    required this.subtitle,
  });

  final Widget leading;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.lg,
        RevericSpacing.lg,
        RevericSpacing.lg,
        RevericSpacing.sm,
      ),
      child: Row(
        children: [
          leading,
          const SizedBox(width: RevericSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: typo.uiSemibold.copyWith(color: colors.textPrimary),
                ),
                const SizedBox(height: 1),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typo.uiTiny.copyWith(color: colors.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 单个模型行：provider 图标盒 + 模型名/厂商 + 右侧（effort 药丸 / 对勾 / 门禁 CTA）。
class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.option,
    required this.selected,
    required this.disabled,

    required this.displayEffort,
    required this.colors,
    required this.typo,
    required this.onSelect,
    required this.onOpenEffort,
  });

  final AiModelOption option;
  final bool selected;
  final bool disabled;
  final String? displayEffort;
  final RevericColors colors;
  final RevericTypography typo;
  final VoidCallback onSelect;
  final VoidCallback onOpenEffort;

  bool get _isReasoning => displayEffort != null;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(RevericRadius.large),
      onTap: disabled ? null : onSelect,
      child: Container(
        decoration: BoxDecoration(
          color: selected ? colors.selected : Colors.transparent,
          borderRadius: BorderRadius.circular(RevericRadius.large),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.md,
          vertical: RevericSpacing.sm + 2,
        ),
        child: Row(
          children: [
            _IconBox(
              icon: providerModelIcon(option.providerId),
              colors: colors,
              size: 32,
              iconSize: 16,
              muted: disabled,
            ),
            const SizedBox(width: RevericSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    option.displayModelName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typo.uiMedium.copyWith(
                      color: disabled ? colors.textSubtle : colors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    option.providerDisplayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: typo.uiTiny.copyWith(
                      color: disabled ? colors.textSubtle : colors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: RevericSpacing.sm),
            if (_isReasoning)
              _EffortPill(
                efforts: option.reasoningEfforts!,
                effort: displayEffort!,
                selected: selected,
                colors: colors,
                typo: typo,
                onTap: onOpenEffort,
              )
            else if (selected)
              RevericIcon(RevericIcons.check, size: 18, color: colors.accent),
          ],
        ),
      ),
    );
  }
}

/// 推理模型行右侧的 effort 药丸：竖条 + 档位标签 + `>`，点击下钻推理强度子菜单。
class _EffortPill extends StatelessWidget {
  const _EffortPill({
    required this.efforts,
    required this.effort,
    required this.selected,
    required this.colors,
    required this.typo,
    required this.onTap,
  });

  final List<String> efforts;
  final String effort;
  final bool selected;
  final RevericColors colors;
  final RevericTypography typo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          RevericSpacing.sm,
          4,
          RevericSpacing.xs,
          4,
        ),
        decoration: BoxDecoration(
          color: selected
              ? colors.accentWarm.withValues(alpha: 0.10)
              : colors.surface,
          borderRadius: BorderRadius.circular(RevericRadius.full),
          border: Border.all(
            color: selected
                ? colors.accentWarm.withValues(alpha: 0.35)
                : colors.borderSubtle,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ReasoningEffortBars(
              total: efforts.length,
              level: efforts.indexOf(effort),
            ),
            const SizedBox(width: RevericSpacing.xs),
            Text(
              reasoningEffortLabelOf(context, effort),
              style: typo.uiTiny.copyWith(
                color: colors.accentWarm,
                fontWeight: FontWeight.w600,
              ),
            ),
            RevericIcon(
              RevericIcons.chevron_right,
              size: 14,
              color: colors.textSubtle,
            ),
          ],
        ),
      ),
    );
  }
}

/// 圆角图标盒（accent 底色）：标题栏 leading 与模型行 provider 图标共用。
class _IconBox extends StatelessWidget {
  const _IconBox({
    required this.icon,
    required this.colors,
    this.size = 34,
    this.iconSize = 18,
    this.muted = false,
  });

  final String icon;
  final RevericColors colors;
  final double size;
  final double iconSize;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: colors.accent.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(9),
      ),
      alignment: Alignment.center,
      child: RevericIcon(
        icon,
        size: iconSize,
        color: muted ? colors.textSubtle : colors.accent,
      ),
    );
  }
}

/// 第二级标题栏返回键。
class _BackButton extends StatelessWidget {
  const _BackButton({required this.colors, required this.onTap});

  final RevericColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colors.surfaceContainer,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: SizedBox(
          width: 34,
          height: 34,
          child: Center(
            child: RevericIcon(
              RevericIcons.arrow_back,
              size: 19,
              color: colors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
