// 职责: 添加自定义供应商时选择接口格式 — 按能力筛选并展示各类型的能力与固定地址标记。
// 关联文件:
//   lib/shared/models/ai_provider.dart
//   lib/shared/widgets/settings/ai_providers_section.dart
//   lib/shared/widgets/settings/provider_config_panel.dart
//   lib/shared/components/reveric_filter_chip.dart
//   lib/mobile/widgets/sheet.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/hooks.md
//   .agents/rules/i18n.md

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../../mobile/widgets/sheet.dart';
import '../../components/reveric_filter_chip.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/ai_provider.dart';
import '../../theme/theme.dart';
import 'ai_providers_section.dart' show localizedProviderTypeName;

const _pickerKinds = [
  AiModelKind.chat,
  AiModelKind.image,
  AiModelKind.video,
  AiModelKind.audio,
];

/// 可新建的类型：OpenAI 兼容最常用放首位，固定地址的平台排在可改地址的格式之后。
/// Codex 依赖桌面登录，移动端不提供。
List<AiProviderType> providerTypePickerTypes() {
  final mobile =
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
  final types = [
    for (final type in customAiProviderTypes)
      if (!mobile || type != AiProviderType.codex) type,
  ];
  bool fixed(AiProviderType type) =>
      aiProviderTypeConfigs[type]?.fixedBaseUrl ?? false;
  int rank(AiProviderType type) => type == AiProviderType.openai_compatible
      ? 0
      : fixed(type)
      ? 2
      : 1;
  return [
    for (final r in [0, 1, 2])
      for (final type in types)
        if (rank(type) == r) type,
  ];
}

String providerKindLabel(BuildContext context, AiModelKind kind) =>
    context.t(switch (kind) {
      AiModelKind.chat => LocaleKeys.settingsProviderKindChat,
      AiModelKind.image => LocaleKeys.settingsProviderKindImage,
      AiModelKind.video => LocaleKeys.settingsProviderKindVideo,
      AiModelKind.audio => LocaleKeys.settingsProviderKindAudio,
    });

/// 类型的可选能力。
List<AiModelKind> providerTypePickerKinds(AiProviderType type) {
  final kinds = aiProviderTypeConfigs[type]?.supportedModelKinds ?? const {};
  return [
    for (final kind in _pickerKinds)
      if (kinds.contains(kind)) kind,
  ];
}

/// 桌面 popover 面板：固定宽度的浮层卡片。
class ProviderTypePickerPanel extends StatelessWidget {
  const ProviderTypePickerPanel({
    super.key,
    required this.onPick,
    this.selected,
  });

  final ValueChanged<AiProviderType> onPick;
  final AiProviderType? selected;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Material(
      type: MaterialType.transparency,
      child: Container(
        width: RevericSizes.providerTypePickerWidth,
        constraints: const BoxConstraints(
          maxHeight: RevericSizes.providerTypePickerMaxHeight,
        ),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(RevericRadius.card),
          border: Border.all(color: revericCardBorder(colors)),
          boxShadow: revericCardShadows(colors),
        ),
        child: ProviderTypePicker(
          onPick: onPick,
          selected: selected,
          showHeader: true,
        ),
      ),
    );
  }
}

/// 移动端底部弹层；返回选中的类型，取消返回 null。
Future<AiProviderType?> showProviderTypeSheet(
  BuildContext context, {
  AiProviderType? selected,
}) {
  return showMobileSheet<AiProviderType>(
    context: context,
    builder: (sheetContext) => MobileSheetScaffold(
      expand: true,
      header: MobileSheetHeader.closable(
        title: sheetContext.t(LocaleKeys.settingsProviderTypePickerTitle),
        onClose: () => Navigator.of(sheetContext).pop(),
      ),
      child: ProviderTypePicker(
        selected: selected,
        showHeader: false,
        onPick: (type) => Navigator.of(sheetContext).pop(type),
      ),
    ),
  );
}

/// 能力筛选 + 类型列表；桌面面板和移动弹层共用。
class ProviderTypePicker extends HookWidget {
  const ProviderTypePicker({
    super.key,
    required this.onPick,
    required this.showHeader,
    this.selected,
  });

  final ValueChanged<AiProviderType> onPick;
  final bool showHeader;
  final AiProviderType? selected;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final filter = useState<AiModelKind?>(null);
    final types = [
      for (final type in providerTypePickerTypes())
        if (filter.value == null ||
            providerTypePickerKinds(type).contains(filter.value))
          type,
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showHeader)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              RevericSpacing.md,
              RevericSpacing.md,
              RevericSpacing.md,
              RevericSpacing.xxs,
            ),
            child: Text(
              context.t(LocaleKeys.settingsProviderTypePickerTitle),
              style: typo.uiSmallSemibold.copyWith(color: colors.textPrimary),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSpacing.md,
            vertical: RevericSpacing.sm,
          ),
          child: Wrap(
            spacing: RevericSpacing.xxs,
            runSpacing: RevericSpacing.xxs,
            children: [
              RevericFilterChip(
                label: context.t(LocaleKeys.commonFilterAll),
                selected: filter.value == null,
                onTap: () => filter.value = null,
              ),
              for (final kind in _pickerKinds)
                RevericFilterChip(
                  label: providerKindLabel(context, kind),
                  selected: filter.value == kind,
                  onTap: () => filter.value = kind,
                ),
            ],
          ),
        ),
        Divider(
          height: RevericSizes.dividerThickness,
          color: colors.borderSubtle,
        ),
        Flexible(
          child: ListView.builder(
            shrinkWrap: true,
            padding: const EdgeInsets.all(RevericSpacing.xs),
            itemCount: types.length,
            itemBuilder: (context, i) => _TypeRow(
              type: types[i],
              highlight: filter.value,
              selected: types[i] == selected,
              onTap: () => onPick(types[i]),
            ),
          ),
        ),
      ],
    );
  }
}

class _TypeRow extends StatelessWidget {
  const _TypeRow({
    required this.type,
    required this.highlight,
    required this.selected,
    required this.onTap,
  });

  final AiProviderType type;
  final AiModelKind? highlight;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final fixed = aiProviderTypeConfigs[type]?.fixedBaseUrl ?? false;
    final noteKey = switch (type) {
      AiProviderType.openai_compatible =>
        LocaleKeys.settingsProviderTypeNoteOpenaiCompatible,
      AiProviderType.minimax => LocaleKeys.settingsProviderTypeNoteMinimax,
      AiProviderType.doubao => LocaleKeys.settingsProviderTypeNoteDoubao,
      _ => null,
    };

    return Material(
      color: selected ? colors.selected : Colors.transparent,
      borderRadius: BorderRadius.circular(RevericRadius.medium),
      child: InkWell(
        onTap: onTap,
        hoverColor: colors.hover,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSpacing.md,
            vertical: RevericSpacing.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: RevericSpacing.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    localizedProviderTypeName(context, type),
                    style: typo.uiSmall.copyWith(
                      fontWeight: FontWeight.w500,
                      color: colors.textPrimary,
                    ),
                  ),
                  if (fixed)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        RevericIcon(
                          RevericIcons.lock_outline,
                          size: 12,
                          color: colors.textSubtle,
                        ),
                        const SizedBox(width: RevericSpacing.xxs),
                        Text(
                          context.t(LocaleKeys.settingsProviderTypeFixedUrl),
                          style: typo.uiTiny.copyWith(color: colors.textSubtle),
                        ),
                      ],
                    ),
                ],
              ),
              if (noteKey != null) ...[
                const SizedBox(height: RevericSpacing.xxs),
                Text(
                  context.t(noteKey),
                  style: typo.uiTiny.copyWith(color: colors.textMuted),
                ),
              ],
              const SizedBox(height: RevericSpacing.xs),
              ProviderKindTags(
                kinds: providerTypePickerKinds(type),
                highlight: highlight,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 能力标签行；[highlight] 对应当前筛选的能力。
class ProviderKindTags extends StatelessWidget {
  const ProviderKindTags({super.key, required this.kinds, this.highlight});

  final List<AiModelKind> kinds;
  final AiModelKind? highlight;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Wrap(
      spacing: RevericSpacing.xxs,
      runSpacing: RevericSpacing.xxs,
      children: [
        for (final kind in kinds)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.xs),
            decoration: BoxDecoration(
              color: kind == highlight
                  ? colors.accentAmber.withValues(alpha: 0.15)
                  : colors.surfaceContainer,
              borderRadius: BorderRadius.circular(RevericRadius.small),
            ),
            child: Text(
              providerKindLabel(context, kind),
              style: typo.uiTiny.copyWith(
                color: kind == highlight
                    ? colors.accentAmber
                    : colors.textMuted,
              ),
            ),
          ),
      ],
    );
  }
}
