// 职责: 新建自定义供应商的草稿 — 生成与换类型、保存落库，以及草稿态表单里的提示和类型选择。
// 关联文件:
//   lib/shared/widgets/settings/ai_providers_section.dart
//   lib/shared/widgets/settings/provider_config_panel.dart
//   lib/shared/widgets/settings/provider_type_picker.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/models/ai_provider.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/provider.json
//   assets/translations/zh-CN/provider.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/state-management.md
//   .agents/rules/i18n.md

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../components/reveric_badge.dart';
import '../../components/reveric_popover.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/ai_provider.dart';
import '../../providers/settings_providers.dart';
import '../../theme/theme.dart';
import '../../utils/random_id.dart';
import '../unsaved_changes_dialog.dart';
import 'ai_providers_section.dart' show localizedProviderTypeName;
import 'provider_type_picker.dart';

/// 未落库的新供应商；名称默认取类型名，保存前只存在于编辑界面。
AiProvider newProviderDraft(BuildContext context, AiProviderType type) =>
    _applyType(
      AiProvider(
        audioModels: const [],
        videoModels: const [],
        id: buildRandomId('prv', length: 6),
        name: localizedProviderTypeName(context, type),
        builtin: false,
        type: type.name,
        enabled: false,
        apiKey: '',
        baseUrl: '',
        models: const [],
        imageModels: const [],
        deletedAt: DateTime.fromMillisecondsSinceEpoch(0),
        embeddingModels: const [],
        temperature: 0.7,
        maxTurns: 512,
        proxyUrl: '',
        proxyUsername: '',
        proxyPassword: '',
        updatedAt: DateTime.now(),
      ),
      type,
    );

/// 草稿换类型：名称仍是旧类型名时跟着换，地址与类型相关的预设一并重置。
AiProvider retypeProviderDraft(
  BuildContext context,
  AiProvider draft,
  AiProviderType type,
) {
  final renamed =
      draft.name == localizedProviderTypeName(context, draft.typeEnum)
      ? localizedProviderTypeName(context, type)
      : draft.name;
  return _applyType(draft.copyWith(type: type.name, name: renamed), type);
}

AiProvider _applyType(AiProvider draft, AiProviderType type) => draft.copyWith(
  baseUrl: aiProviderTypeConfigs[type]?.fixedBaseUrl == true
      ? aiProviderFixedBaseUrl(type)
      : '',
  videoModels: type == AiProviderType.metaso
      ? aiProviderBuiltinById('metaso')!.videoModels
      : const [],
);

/// 草稿保存条件；名称为空时不能创建。
bool canSaveProviderDraft(AiProvider draft) => draft.name.trim().isNotEmpty;

/// 写入草稿并返回新供应商 ID；配置已满足启用条件时直接启用。
Future<String> saveProviderDraft(WidgetRef ref, AiProvider draft) {
  final config = draft.copyWith(
    name: draft.name.trim(),
    enabled: draft.enableValidationMessage == null,
    updatedAt: DateTime.now(),
  );
  return ref.read(appSettingsProvider.notifier).addCustomProvider(config);
}

/// 离开草稿前询问保存、丢弃或继续编辑；名称为空时不提供保存。
Future<UnsavedChangesDecision?> askLeaveProviderDraft(
  BuildContext context,
  AiProvider draft,
) => showUnsavedChangesDialog(
  context: context,
  titleKey: LocaleKeys.editorUnsavedChangesTitle,
  messageKey: LocaleKeys.editorUnsavedChangesMessage,
  showSave: canSaveProviderDraft(draft),
);

class ProviderDraftBadge extends StatelessWidget {
  const ProviderDraftBadge({super.key});

  @override
  Widget build(BuildContext context) => RevericBadge(
    label: context.t(LocaleKeys.providerDraftBadge),
    color: RevericTheme.colorsOf(context).warningText,
  );
}

/// 草稿的类型字段：显示当前类型与能力，点击重新选择（桌面 popover，移动端底部弹层）。
class ProviderDraftTypeField extends StatelessWidget {
  const ProviderDraftTypeField({
    super.key,
    required this.type,
    required this.onChanged,
  });

  final AiProviderType type;
  final ValueChanged<AiProviderType> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final mobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;

    Widget field(VoidCallback onTap) => Material(
      color: colors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(RevericRadius.medium),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(RevericRadius.medium),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSpacing.md,
            vertical: RevericSpacing.sm,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(RevericRadius.medium),
            border: Border.all(color: colors.borderInput),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  localizedProviderTypeName(context, type),
                  style: typo.ui.copyWith(color: colors.textPrimary),
                ),
              ),
              const SizedBox(width: RevericSpacing.sm),
              ProviderKindTags(kinds: providerTypePickerKinds(type)),
              const SizedBox(width: RevericSpacing.xs),
              RevericIcon(
                mobile
                    ? RevericIcons.keyboard_arrow_right
                    : RevericIcons.expand_more,
                size: 16,
                color: colors.textMuted,
              ),
            ],
          ),
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.t(LocaleKeys.providerTypeLabel),
          style: typo.uiSemibold.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: RevericSpacing.xs),
        if (mobile)
          field(() async {
            final next = await showProviderTypeSheet(context, selected: type);
            if (next != null && next != type) {
              onChanged(next);
            }
          })
        else
          RevericPopover(
            trigger: (context, open, toggle) => field(toggle),
            panel: (context, close) => ProviderTypePickerPanel(
              selected: type,
              onPick: (next) {
                close();
                if (next != type) {
                  onChanged(next);
                }
              },
            ),
          ),
        const SizedBox(height: RevericSpacing.xs),
        Text(
          context.t(LocaleKeys.providerDraftTypeHint),
          style: typo.uiSmall.copyWith(color: colors.textMuted),
        ),
      ],
    );
  }
}
