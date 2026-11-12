// 职责: 添加供应商时优先展示预设平台，并按接入方式与模型能力筛选。
// 关联文件:
//   lib/shared/models/ai_provider.dart
//   lib/shared/widgets/settings/ai_providers_section.dart
//   lib/shared/widgets/settings/provider_config_panel.dart
//   lib/shared/components/reveric_filter_chip.dart
//   lib/mobile/widgets/sheet.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/provider.json
//   assets/translations/zh-CN/provider.json
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
import '../../components/reveric_segmented_control.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/ai_provider.dart';
import '../../theme/theme.dart';
import 'ai_providers_section.dart' show localizedProviderTypeName;
import 'provider_logo.dart';

const _pickerKinds = [
  AiModelKind.chat,
  AiModelKind.image,
  AiModelKind.video,
  AiModelKind.audio,
];

/// 预设平台优先，本机 Codex 登录列在平台末尾；通用接口以 OpenAI 兼容开头。
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
  int rank(AiProviderType type) => fixed(type)
      ? (type == AiProviderType.codex ? 1 : 0)
      : (type == AiProviderType.openai_compatible ? 2 : 3);
  return [
    for (final r in [0, 1, 2, 3])
      for (final type in types)
        if (rank(type) == r) type,
  ];
}

String providerKindLabel(BuildContext context, AiModelKind kind) =>
    context.t(switch (kind) {
      AiModelKind.chat => LocaleKeys.providerKindChat,
      AiModelKind.image => LocaleKeys.providerKindImage,
      AiModelKind.video => LocaleKeys.providerKindVideo,
      AiModelKind.audio => LocaleKeys.providerKindAudio,
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
        title: sheetContext.t(LocaleKeys.providerTypePickerTitle),
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
    final presets = useState(
      selected == null || aiProviderTypeConfigs[selected]!.fixedBaseUrl,
    );
    final segmentTypes = [
      for (final type in providerTypePickerTypes())
        if (aiProviderTypeConfigs[type]!.fixedBaseUrl == presets.value) type,
    ];
    int countOf(AiModelKind kind) => segmentTypes
        .where((type) => providerTypePickerKinds(type).contains(kind))
        .length;
    // 切换分段后，若原能力在新分段下无结果，回落到「全部」而不是展示空列表。
    final kind = filter.value;
    final activeFilter = kind != null && countOf(kind) > 0 ? kind : null;
    final types = [
      for (final type in segmentTypes)
        if (activeFilter == null ||
            providerTypePickerKinds(type).contains(activeFilter))
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
              context.t(LocaleKeys.providerTypePickerTitle),
              style: typo.uiSmallSemibold.copyWith(color: colors.textPrimary),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            RevericSpacing.md,
            RevericSpacing.sm,
            RevericSpacing.md,
            RevericSpacing.xxs,
          ),
          child: RevericSegmentedControl<bool>(
            selected: presets.value,
            onChanged: (value) => presets.value = value,
            segments: [
              RevericSegment(
                value: true,
                label: context.t(LocaleKeys.providerTypePresets),
              ),
              RevericSegment(
                value: false,
                label: context.t(LocaleKeys.providerTypeProtocols),
              ),
            ],
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
                selected: activeFilter == null,
                onTap: () => filter.value = null,
              ),
              for (final kind in _pickerKinds)
                RevericFilterChip(
                  label: providerKindLabel(context, kind),
                  selected: activeFilter == kind,
                  onTap: countOf(kind) == 0 ? null : () => filter.value = kind,
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
            key: ValueKey((presets.value, activeFilter)),
            shrinkWrap: true,
            padding: const EdgeInsets.all(RevericSpacing.xs),
            itemCount: types.length,
            itemBuilder: (context, i) => _TypeRow(
              type: types[i],
              highlight: activeFilter,
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
    final noteKey = switch (type) {
      AiProviderType.openai_compatible =>
        LocaleKeys.providerTypeNoteOpenaiCompatible,
      AiProviderType.minimax => LocaleKeys.providerTypeNoteMinimax,
      AiProviderType.doubao => LocaleKeys.providerTypeNoteDoubao,
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
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ProviderLogo(type: type.name),
              const SizedBox(width: RevericSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      localizedProviderTypeName(context, type),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typo.uiSmall.copyWith(
                        fontWeight: FontWeight.w500,
                        color: colors.textPrimary,
                      ),
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
