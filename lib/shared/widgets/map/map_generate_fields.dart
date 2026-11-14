// 职责: 地图出图参数字段 — 目标地图、Agent 草稿卡、来源开关、画风/分辨率/质量、提示词。
//       不含滚动容器与生成脚：桌面放进制图师「生成」tab，移动端放进参数抽屉。
// 关联文件:
//   lib/shared/hooks/use_map_generate_form.dart
//   lib/shared/widgets/map/map_agent_draft_card.dart
//   lib/shared/widgets/map/map_generate_footer.dart
//   lib/shared/providers/map_agent_providers.dart
//   lib/shared/services/map_prompt_builder.dart
//   lib/desktop/features/map/map_cartographer_panel.dart
//   lib/mobile/features/map/designer_sheet.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/map_editor.json
//   assets/translations/zh-CN/map_editor.json
//   assets/translations/en/editor.json
//   assets/translations/zh-CN/editor.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
//   .agents/rules/i18n.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../components/reveric_text_field.dart';
import '../../hooks/use_map_generate_form.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/map_agent.dart' show mapCustomStyleId;
import '../../providers/map_agent_providers.dart';
import '../../services/map_prompt_builder.dart';
import '../../theme/theme.dart';
import 'map_agent_draft_card.dart';

typedef MapAgentHandoffCallback =
    void Function({required String? styleId, required String? styleWord});

class MapGenerateFields extends HookConsumerWidget {
  const MapGenerateFields({
    super.key,
    required this.form,
    required this.databasePath,
    required this.rootId,
    required this.rootName,
    required this.busy,
    this.onAskAgent,
    this.showTarget = true,
    this.touchTargets = false,
  });

  final MapGenerateForm form;
  final String databasePath;

  /// 参与生成的地点树根，同时是 Agent 草稿的查找键。
  final String rootId;

  /// 生成目标地图的名字：生成针对画布这张图，而不是选中的地点。
  final String rootName;
  final bool busy;

  /// 「让 Agent 设计」；null 时不显示入口。
  final MapAgentHandoffCallback? onAskAgent;

  /// 顶部的目标地图行；移动端抽屉标题已经写了地图名时关掉。
  final bool showTarget;

  /// 触屏布局：chip 与来源开关撑到 [RevericSizes.buttonHeight] 的点击高度。
  final bool touchTargets;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    useListenable(form.listenable);
    final referenceCount =
        (form.effectiveReferenceCurrentImage ? 1 : 0) +
        (form.effectiveReferenceParent ? 1 : 0);
    final referenceLimit = form.choices?.referenceLimit;
    final canAddReference =
        referenceLimit == null || referenceCount < referenceLimit;
    final agentDraft = ref.watch(
      mapDesignDraftProvider(databasePath: databasePath, worldId: rootId),
    );

    void discardAgentDraft() {
      ref
          .read(mapDesignDraftsProvider.notifier)
          .discard(databasePath: databasePath, worldId: rootId);
    }

    void askAgent() {
      final callback = onAskAgent;
      if (callback == null || !form.validateCustomStyle()) {
        return;
      }
      callback(styleId: form.styleId.value, styleWord: form.currentStyleWord());
    }

    Widget sectionLabel(String key) => Text(
      context.t(key),
      style: typo.uiSmallSemibold.copyWith(color: colors.textSecondary),
    );

    final styleId = form.styleId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showTarget) ...[
          Row(
            key: const ValueKey('map_generate_target'),
            children: [
              RevericIcon(
                RevericIcons.map_outlined,
                size: 14,
                color: colors.textMuted,
              ),
              const SizedBox(width: RevericSpacing.sm),
              Expanded(
                child: Text(
                  rootName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typo.uiSemibold,
                ),
              ),
            ],
          ),
          const SizedBox(height: RevericSpacing.lg),
        ],
        if (agentDraft != null) ...[
          MapAgentDraftCard(
            draft: agentDraft,
            onApply: () {
              form.applyDraft(agentDraft);
              discardAgentDraft();
            },
            onDismiss: discardAgentDraft,
          ),
          const SizedBox(height: RevericSpacing.lg),
        ],
        sectionLabel(LocaleKeys.mapEditorStudioSources),
        const SizedBox(height: RevericSpacing.sm),
        _SourceToggle(
          label: context.t(LocaleKeys.mapEditorStudioSourceLocations),
          note: context.t(LocaleKeys.mapEditorStudioSourceLocationsNote),
          value: form.includeLocations.value,
          touchTarget: touchTargets,
          onChanged: (value) => form.includeLocations.value = value,
        ),
        if (form.hasImage) ...[
          const SizedBox(height: RevericSpacing.sm),
          _SourceToggle(
            key: const ValueKey('map_studio_reference_current_image_toggle'),
            label: context.t(LocaleKeys.mapEditorStudioSourceCurrentImage),
            note: context.t(LocaleKeys.mapEditorStudioSourceCurrentImageNote),
            value: form.effectiveReferenceCurrentImage,
            touchTarget: touchTargets,
            onChanged:
                busy ||
                    (!form.effectiveReferenceCurrentImage && !canAddReference)
                ? null
                : (value) => form.referenceCurrentImage.value = value,
          ),
        ],
        if (form.parentMap != null) ...[
          const SizedBox(height: RevericSpacing.sm),
          _SourceToggle(
            key: const ValueKey('map_studio_reference_parent_image_toggle'),
            label: context.t(LocaleKeys.mapEditorStudioSourceParentImage),
            note: context
                .t(LocaleKeys.mapEditorStudioSourceParentImageNote)
                .replaceFirst('{name}', form.parentMapName ?? ''),
            value: form.effectiveReferenceParent,
            touchTarget: touchTargets,
            onChanged:
                busy || (!form.effectiveReferenceParent && !canAddReference)
                ? null
                : (value) => form.referenceParentImage.value = value,
          ),
        ],
        const SizedBox(height: RevericSpacing.lg),
        sectionLabel(LocaleKeys.mapEditorStudioStyle),
        const SizedBox(height: RevericSpacing.sm),
        Wrap(
          spacing: RevericSpacing.sm,
          runSpacing: RevericSpacing.sm,
          children: [
            for (final option in mapStyleOptions)
              _Chip(
                key: ValueKey('map_studio_style_${option.id}'),
                label: context.t(_styleLabelKey(option.id)),
                selected: styleId.value == option.id,
                touchTarget: touchTargets,
                onTap: () {
                  styleId.value = styleId.value == option.id ? null : option.id;
                  form.customStyleError.value = false;
                },
              ),
            _Chip(
              key: const ValueKey('map_studio_style_custom'),
              label: context.t(LocaleKeys.mapEditorStudioStyleCustom),
              selected: styleId.value == mapCustomStyleId,
              touchTarget: touchTargets,
              onTap: () {
                final selectCustom = styleId.value != mapCustomStyleId;
                styleId.value = selectCustom ? mapCustomStyleId : null;
                form.customStyleError.value = false;
                if (selectCustom) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    form.customStyleFocusNode.requestFocus();
                  });
                }
              },
            ),
          ],
        ),
        if (styleId.value == mapCustomStyleId) ...[
          const SizedBox(height: RevericSpacing.sm),
          RevericTextField(
            key: const ValueKey('map_studio_custom_style_field'),
            controller: form.customStyleController,
            focusNode: form.customStyleFocusNode,
            enabled: !busy,
            hintText: context.t(LocaleKeys.mapEditorStudioStyleCustomHint),
            errorText: form.customStyleError.value
                ? context.t(LocaleKeys.mapEditorStudioStyleCustomRequired)
                : null,
            onChanged: (value) {
              if (form.customStyleError.value && value.trim().isNotEmpty) {
                form.customStyleError.value = false;
              }
            },
          ),
        ],
        for (final field in [
          (
            LocaleKeys.editorCoverRatio,
            form.choices?.ratios ?? <String>[],
            form.ratioId,
          ),
          (
            LocaleKeys.mapEditorStudioResolution,
            form.choices?.resolutions ?? <String>[],
            form.resolutionId,
          ),
          (
            LocaleKeys.mapEditorStudioQuality,
            form.choices?.qualities ?? <String>[],
            form.qualityId,
          ),
          (
            LocaleKeys.commonComplexity,
            form.choices?.complexities ?? <String>[],
            form.complexityId,
          ),
        ]) ...[
          if (field.$2.isNotEmpty) ...[
            const SizedBox(height: RevericSpacing.lg),
            sectionLabel(field.$1),
            const SizedBox(height: RevericSpacing.sm),
            Wrap(
              spacing: RevericSpacing.sm,
              runSpacing: RevericSpacing.sm,
              children: [
                for (final option in field.$2)
                  _Chip(
                    label: option,
                    selected: field.$3.value == option,
                    touchTarget: touchTargets,
                    onTap: busy || field.$2.length == 1
                        ? null
                        : () => field.$3.value = option,
                  ),
              ],
            ),
          ],
        ],
        const SizedBox(height: RevericSpacing.lg),
        Row(
          key: const ValueKey('map_prompt_header'),
          children: [
            Expanded(child: sectionLabel(LocaleKeys.mapEditorStudioPrompt)),
            if (onAskAgent != null)
              Tooltip(
                message: context.t(LocaleKeys.mapEditorAgentAsk),
                child: Semantics(
                  button: true,
                  enabled: !busy,
                  child: InkWell(
                    key: const ValueKey('map_ask_agent'),
                    onTap: busy ? null : askAgent,
                    borderRadius: BorderRadius.circular(RevericRadius.small),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: RevericSpacing.xs,
                        vertical: 4,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          RevericIcon(
                            RevericIcons.auto_awesome,
                            size: 14,
                            color: busy ? colors.textSubtle : colors.accent,
                          ),
                          const SizedBox(width: RevericSpacing.xxs),
                          Text(
                            context.t(LocaleKeys.mapEditorAgentAsk),
                            style: typo.uiSmall.copyWith(
                              color: busy ? colors.textSubtle : colors.accent,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            const SizedBox(width: RevericSpacing.xs),
            GestureDetector(
              key: const ValueKey('map_prompt_reset'),
              behavior: HitTestBehavior.opaque,
              onTap: busy ? null : form.resetPrompt,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  vertical: touchTargets ? RevericSpacing.sm : 0,
                ),
                child: Text(
                  context.t(LocaleKeys.mapEditorStudioPromptReset),
                  style: typo.uiSmall.copyWith(color: colors.accent),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: RevericSpacing.sm),
        RevericTextField(
          key: const ValueKey('map_studio_prompt_field'),
          controller: form.promptController,
          enabled: !busy,
          multiline: true,
          minLines: 6,
          maxLines: 12,
          hintText: context.t(LocaleKeys.mapEditorStudioPromptHint),
          // 提示词偏长，用小号字塞进窄面板（同封面工作台）。
          style: typo.uiSmall.copyWith(height: 1.5),
        ),
      ],
    );
  }
}

class _SourceToggle extends StatelessWidget {
  const _SourceToggle({
    super.key,
    required this.label,
    this.note,
    required this.value,
    required this.touchTarget,
    required this.onChanged,
  });

  final String label;
  final String? note;
  final bool value;
  final bool touchTarget;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return GestureDetector(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      behavior: HitTestBehavior.opaque,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: touchTarget ? RevericSizes.buttonHeight : 0,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: RevericSpacing.xs),
          child: Row(
            children: [
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: value ? colors.accent : colors.border,
                    width: 1.5,
                  ),
                  color: value ? colors.accent : Colors.transparent,
                ),
                child: value
                    ? const RevericIcon(RevericIcons.check, size: 11)
                    : null,
              ),
              const SizedBox(width: RevericSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: typo.uiSmall),
                    if (note != null)
                      Text(
                        note!,
                        style: typo.uiTiny.copyWith(color: colors.textMuted),
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

class _Chip extends StatelessWidget {
  const _Chip({
    super.key,
    required this.label,
    required this.selected,
    required this.touchTarget,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool touchTarget;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        // 触屏靠上下内边距撑出点击高度；不能设 alignment，否则在 Wrap 里会撑满整行。
        padding: EdgeInsets.symmetric(
          horizontal: touchTarget ? RevericSpacing.lg : RevericSpacing.md,
          vertical: touchTarget ? RevericSpacing.sm : 5,
        ),
        decoration: BoxDecoration(
          color: selected
              ? colors.accent.withValues(alpha: 0.12)
              : colors.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: selected ? colors.accent : colors.border),
        ),
        child: Text(
          label,
          style: typo.uiSmall.copyWith(
            color: selected ? colors.accent : colors.textSecondary,
          ),
        ),
      ),
    );
  }
}

String _styleLabelKey(String id) => switch (id) {
  'inkmap' => LocaleKeys.mapEditorStudioStyleInkmap,
  'engraving' => LocaleKeys.mapEditorStudioStyleEngraving,
  'realistic' => LocaleKeys.mapEditorStudioStyleRealistic,
  'woodcut' => LocaleKeys.mapEditorStudioStyleWoodcut,
  'watercolor' => LocaleKeys.mapEditorStudioStyleWatercolor,
  'atlas' => LocaleKeys.mapEditorStudioStyleAtlas,
  _ => LocaleKeys.mapEditorStudioStyleParchment,
};
