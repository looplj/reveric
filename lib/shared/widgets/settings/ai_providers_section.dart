// 职责: 共享 AI provider 设置区 — 桌面两栏 / 移动列表的组合，以及新建自定义供应商的选类型与草稿流程。
// 关联文件:
//   lib/shared/widgets/settings/provider_config_panel.dart
//   lib/shared/widgets/settings/provider_draft.dart
//   lib/shared/widgets/settings/provider_type_picker.dart
//   lib/shared/widgets/settings/mobile_provider_list.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/settings.json
//   assets/translations/en/provider.json
//   assets/translations/zh-CN/settings.json
//   assets/translations/zh-CN/provider.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/hooks.md
//   .agents/rules/widget-decomposition.md

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../components/reveric_badge.dart';
import '../../components/reveric_button.dart';
import '../../components/reveric_icon_button.dart';
import '../../components/reveric_placeholder.dart';
import '../../components/reveric_popover.dart';
import '../../components/reveric_search_field.dart';
import '../../localization/ai_provider_localization.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/ai_provider.dart';
import '../../providers/settings_providers.dart';
import '../../theme/theme.dart';
import '../unsaved_changes_dialog.dart';
import 'leave_guard.dart';
import 'mobile_provider_list.dart';
import 'provider_config_panel.dart';
import 'provider_draft.dart';
import 'provider_logo.dart';
import 'provider_overview.dart';
import 'provider_type_picker.dart';
import 'providers/registry.dart';

/// AI providers section：左侧 provider 列表 + 右侧配置面板（桌面），
/// 或纯列表 + push 到配置页（移动端及宽度 < 600 的窗口）。
class AiProvidersSection extends ConsumerWidget {
  const AiProvidersSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final settingsAsync = ref.watch(appSettingsProvider);

    return settingsAsync.when(
      loading: () => Center(
        child: SizedBox(
          width: RevericSizes.aiAvatarMd,
          height: RevericSizes.aiAvatarMd,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: colors.accent,
          ),
        ),
      ),
      error: (_, _) => Center(
        child: RevericPlaceholder.error(
          title: context.t(LocaleKeys.commonLoadFailed),
        ),
      ),
      data: (settings) {
        final isMobile =
            defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS;
        final isDesktop = !isMobile && MediaQuery.sizeOf(context).width >= 600;
        return isDesktop
            ? _DesktopProviders(settings: settings)
            : _MobileProviders(settings: settings);
      },
    );
  }
}

/// 桌面两栏：持有选中项与新建草稿。草稿存在时一定处于选中状态，
/// 离开草稿（切换供应商、切换设置分区、关闭设置）前先确认。
class _DesktopProviders extends HookConsumerWidget {
  const _DesktopProviders({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final selectedId = useState<String?>(null);
    final draft = useState<AiProvider?>(null);
    final saving = useState(false);
    // 丢弃草稿后回到新建前选中的供应商。
    final returnTo = useRef<String?>(null);
    final allConfigs = settings.aiSettings.allConfigs;
    final currentDraft = draft.value;

    final effectiveSelectedId =
        currentDraft?.id ??
        (allConfigs.any((c) => c.id == selectedId.value)
            ? selectedId.value
            : (allConfigs.isNotEmpty ? allConfigs.first.id : null));

    final selectedConfig = currentDraft == null && effectiveSelectedId != null
        ? settings.aiSettings.findConfigById(effectiveSelectedId)
        : null;

    Future<bool> saveDraft() async {
      final pending = draft.value;
      if (pending == null || saving.value) {
        return false;
      }
      saving.value = true;
      try {
        final id = await saveProviderDraft(ref, pending);
        if (context.mounted) {
          draft.value = null;
          selectedId.value = id;
        }
        return true;
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.t(LocaleKeys.commonSaveFailed))),
          );
        }
        return false;
      } finally {
        if (context.mounted) {
          saving.value = false;
        }
      }
    }

    void discardDraft() {
      draft.value = null;
      selectedId.value = returnTo.value;
    }

    Future<bool> confirmLeave() async {
      final pending = draft.value;
      if (pending == null) {
        return true;
      }
      if (saving.value) {
        return false;
      }
      final decision = await askLeaveProviderDraft(context, pending);
      switch (decision) {
        case null:
          return false;
        case UnsavedChangesDecision.discard:
          draft.value = null;
          return true;
        case UnsavedChangesDecision.save:
          return saveDraft();
      }
    }

    final leave = SettingsLeaveScope.maybeOf(context);
    final leaveGuard = useRef(confirmLeave);
    leaveGuard.value = confirmLeave;
    useEffect(() {
      if (leave == null) {
        return null;
      }
      Future<bool> guard() => leaveGuard.value();
      leave.register(guard);
      return () => leave.unregister(guard);
    }, [leave]);

    return Row(
      children: [
        SizedBox(
          width: RevericSizes.settingsProviderListWidth,
          child: ProviderList(
            configs: allConfigs,
            draft: currentDraft,
            selectedId: effectiveSelectedId,
            onSelect: (id) async {
              if (id == effectiveSelectedId || !await confirmLeave()) {
                return;
              }
              selectedId.value = id;
            },
            onAddCustom: (type) {
              returnTo.value = effectiveSelectedId;
              draft.value = newProviderDraft(context, type);
            },
          ),
        ),
        Container(width: RevericSizes.dividerThickness, color: colors.border),
        Expanded(
          child: currentDraft != null
              ? ProviderConfigForm(
                  key: ValueKey(currentDraft.id),
                  config: currentDraft,
                  onChanged: (config) async => draft.value = config,
                  onChangeType: (type) => draft.value = retypeProviderDraft(
                    context,
                    draft.value!,
                    type,
                  ),
                  badge: const ProviderDraftBadge(),
                  headerActions: [
                    RevericButton.text(
                      label: context.t(LocaleKeys.commonDiscard),
                      onPressed: saving.value ? null : discardDraft,
                    ),
                    const SizedBox(width: RevericSpacing.xs),
                    RevericButton.primary(
                      label: context.t(LocaleKeys.commonSave),
                      loading: saving.value,
                      onPressed: canSaveProviderDraft(currentDraft)
                          ? saveDraft
                          : null,
                    ),
                  ],
                )
              : selectedConfig != null
              ? ProviderConfigPanel(
                  key: ValueKey(selectedConfig.id),
                  providerId: selectedConfig.id,
                )
              : Center(
                  child: Text(
                    context.t(LocaleKeys.providerSelectPlaceholder),
                    style: RevericTheme.typographyOf(
                      context,
                    ).ui.copyWith(color: colors.textMuted),
                  ),
                ),
        ),
      ],
    );
  }
}

/// 移动端：分组卡片列表，点击进入配置页；添加先选类型，再进入草稿页。
class _MobileProviders extends StatelessWidget {
  const _MobileProviders({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return MobileProviderList(
      configs: settings.aiSettings.allConfigs,

      selectedId: null,

      onSelect: (id) {
        final config = settings.aiSettings.findConfigById(id);
        if (config == null) {
          return;
        }
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => _ProviderConfigRoute(
              title: localizedAiProviderName(context, config),
              providerId: config.id,
            ),
          ),
        );
      },
      onAddCustom: () async {
        final type = await showProviderTypeSheet(context);
        if (type == null || !context.mounted) {
          return;
        }
        final draft = newProviderDraft(context, type);
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => _ProviderDraftRoute(initial: draft),
          ),
        );
      },
    );
  }
}

class _ProviderConfigRoute extends StatelessWidget {
  const _ProviderConfigRoute({required this.title, required this.providerId});

  final String title;
  final String providerId;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(
        backgroundColor: colors.surfaceDim,
        elevation: 0,
        leading: IconButton(
          icon: RevericIcon(RevericIcons.arrow_back, color: colors.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          title,
          style: typo.heading2.copyWith(color: colors.textPrimary),
        ),
      ),
      body: ProviderConfigPanel(
        providerId: providerId,

        onDeleted: () => Navigator.of(context).pop(),
      ),
    );
  }
}

/// 移动端新建页：顶栏「保存」才落库；返回时询问保存、丢弃或继续编辑。
class _ProviderDraftRoute extends HookConsumerWidget {
  const _ProviderDraftRoute({required this.initial});

  final AiProvider initial;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final draft = useState(initial);
    final saving = useState(false);

    Future<void> save() async {
      if (saving.value) {
        return;
      }
      saving.value = true;
      try {
        await saveProviderDraft(ref, draft.value);
        if (context.mounted) {
          Navigator.of(context).pop();
        }
      } catch (_) {
        if (context.mounted) {
          saving.value = false;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.t(LocaleKeys.commonSaveFailed))),
          );
        }
      }
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || saving.value) {
          return;
        }
        final decision = await askLeaveProviderDraft(context, draft.value);
        if (!context.mounted) {
          return;
        }
        switch (decision) {
          case null:
            return;
          case UnsavedChangesDecision.discard:
            Navigator.of(context).pop();
          case UnsavedChangesDecision.save:
            await save();
        }
      },
      child: Scaffold(
        backgroundColor: colors.canvas,
        appBar: AppBar(
          backgroundColor: colors.surfaceDim,
          elevation: 0,
          leading: IconButton(
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            icon: RevericIcon(
              RevericIcons.arrow_back,
              color: colors.textPrimary,
            ),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          title: Text(
            context.t(LocaleKeys.providerNewTitle),
            style: typo.heading2.copyWith(color: colors.textPrimary),
          ),
          actions: [
            RevericButton.text(
              label: context.t(LocaleKeys.commonSave),
              loading: saving.value,
              onPressed: canSaveProviderDraft(draft.value) ? save : null,
            ),
            const SizedBox(width: RevericSpacing.sm),
          ],
        ),
        body: ProviderConfigForm(
          config: draft.value,
          onChanged: (config) async => draft.value = config,
          onChangeType: (type) =>
              draft.value = retypeProviderDraft(context, draft.value, type),
          badge: const ProviderDraftBadge(),
          headerActions: const [],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Provider List
// ─────────────────────────────────────────────────────────────────────────────

class ProviderList extends HookWidget {
  const ProviderList({
    super.key,
    required this.configs,
    required this.selectedId,
    required this.onSelect,
    required this.onAddCustom,
    this.draft,
  });
  final List<AiProvider> configs;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final ValueChanged<AiProviderType> onAddCustom;

  /// 未保存的新供应商，固定显示在列表顶部；存在时不能再新建。
  final AiProvider? draft;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final search = useDebouncedSearch();
    final draft = this.draft;
    final filtered = configs
        .where(
          (config) =>
              '${localizedAiProviderName(context, config)} ${config.type} ${config.videoModels.join(' ')}'
                  .toLowerCase()
                  .contains(search.query),
        )
        .toList();
    final items = [?draft, ...filtered];
    return ColoredBox(
      color: colors.surfaceDim,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(RevericSpacing.sm),
            child: Row(
              children: [
                Expanded(
                  child: RevericSearchField(
                    controller: search.controller,
                    hint: context.t(LocaleKeys.providerSearchHint),
                  ),
                ),
                const SizedBox(width: RevericSpacing.xxs),
                RevericPopover(
                  trigger: (context, open, toggle) => RevericIconButton(
                    icon: RevericIcons.add,
                    tooltip: context.t(LocaleKeys.settingsAddCustomProvider),
                    onPressed: draft == null ? toggle : null,
                  ),
                  panel: (context, close) => ProviderTypePickerPanel(
                    onPick: (type) {
                      close();
                      onAddCustom(type);
                    },
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Text(
                      context.t(LocaleKeys.commonNoResults),
                      style: RevericTheme.typographyOf(
                        context,
                      ).uiSmall.copyWith(color: colors.textMuted),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(
                      horizontal: RevericSpacing.xs,
                      vertical: RevericSpacing.sm,
                    ),
                    itemCount: items.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: RevericSpacing.xxs),
                    itemBuilder: (_, i) => ProviderListItem(
                      config: items[i],
                      draft: items[i].id == draft?.id,
                      isSelected: items[i].id == selectedId,
                      onTap: () => onSelect(items[i].id),
                    ),
                  ),
          ),
          Divider(height: RevericSizes.dividerThickness, color: colors.border),
          Padding(
            padding: const EdgeInsets.all(RevericSpacing.sm),
            // 列表底部向上展开类型选择；已有草稿时先保存或放弃。
            child: RevericPopover(
              up: true,
              trigger: (context, open, toggle) => SizedBox(
                width: double.infinity,
                child: RevericButton.secondary(
                  label: context.t(LocaleKeys.settingsAddCustomProvider),
                  icon: RevericIcons.add,
                  size: RevericButtonSize.compact,
                  onPressed: draft == null ? toggle : null,
                ),
              ),
              panel: (context, close) => ProviderTypePickerPanel(
                onPick: (type) {
                  close();
                  onAddCustom(type);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ProviderListItem extends StatelessWidget {
  final AiProvider config;

  final bool isSelected;
  final bool locked;
  final bool draft;
  final VoidCallback onTap;

  const ProviderListItem({
    super.key,
    required this.config,

    required this.isSelected,
    this.locked = false,
    this.draft = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final showcase = providerShowcases[config.type];

    return Material(
      color: isSelected ? colors.selected : colors.surfaceDim,
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
            children: [
              ProviderLogo(type: config.type),
              const SizedBox(width: RevericSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            localizedAiProviderName(context, config),
                            style:
                                (isSelected
                                        ? typo.uiSmallSemibold
                                        : typo.uiSmall)
                                    .copyWith(color: colors.textPrimary),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    if (config.isTypeSupported) ...[
                      const SizedBox(height: RevericSpacing.xxs),
                      Text(
                        showcase?.listTagline?.call(context) ??
                            providerCapabilitySummary(context, config),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typo.uiTiny.copyWith(color: colors.textMuted),
                      ),
                    ],
                    if (draft) ...[
                      const SizedBox(height: RevericSpacing.xxs),
                      const ProviderDraftBadge(),
                    ] else if (!config.isTypeSupported ||
                        !config.isBuiltin) ...[
                      const SizedBox(height: RevericSpacing.xxs),
                      RevericBadge(
                        label: context.t(
                          config.isTypeSupported
                              ? LocaleKeys.settingsCustomBadge
                              : LocaleKeys.providerUnsupportedBadge,
                        ),
                        color: config.isTypeSupported
                            ? colors.accentWarm
                            : colors.warningText,
                      ),
                    ],
                  ],
                ),
              ),
              if (!draft) ...[
                const SizedBox(width: RevericSpacing.xs),
                ProviderStatusDot(
                  active: config.isValid,
                  size: RevericSizes.statusDotSize,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Status Badge
// ─────────────────────────────────────────────────────────────────────────────

class StatusBadge extends StatelessWidget {
  final bool isValid;
  const StatusBadge({super.key, required this.isValid});

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return RevericBadge(
      label: context.t(
        isValid
            ? LocaleKeys.settingsStatusActive
            : LocaleKeys.settingsStatusInactive,
      ),
      color: isValid ? colors.additionBorder : colors.textMuted,
    );
  }
}

/// 列表项左侧的可用状态圆点；悬停给出与 [StatusBadge] 相同的状态文案。
class ProviderStatusDot extends StatelessWidget {
  final bool active;
  final double size;
  const ProviderStatusDot({
    super.key,
    required this.active,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Tooltip(
      message: context.t(
        active
            ? LocaleKeys.settingsStatusActive
            : LocaleKeys.settingsStatusInactive,
      ),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active ? colors.additionBorder : colors.border,
        ),
      ),
    );
  }
}

/// Provider 类型展示名；兼容协议名称及有中英文品牌名的渠道走 locale key。
String localizedProviderTypeName(BuildContext context, AiProviderType type) {
  if (type == AiProviderType.infistar) {
    return context.t(LocaleKeys.providerTypeInfistar);
  }
  if (type == AiProviderType.metaso) {
    return context.t(LocaleKeys.settingsBuiltinProviderMetaso);
  }
  if (type == AiProviderType.volcengine) {
    return context.t(LocaleKeys.providerTypeVolcengine);
  }
  if (type == AiProviderType.openai_compatible) {
    return context.t(LocaleKeys.providerTypeOpenaiCompatible);
  }
  return aiProviderTypeDisplayNames[type] ?? type.name;
}
