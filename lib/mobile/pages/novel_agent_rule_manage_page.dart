// 职责: 移动端作品级智能体规则管理 — 列表（左滑删除）+ 编辑（名称/内容/启用），复用 shared 层 provider 与表单字段 schema。
// 关联文件:
//   lib/mobile/widgets/agent_edit_scaffold.dart
//   lib/mobile/widgets/section_scaffold.dart
//   lib/mobile/widgets/agent_rule_copy_sheet.dart
//   lib/shared/models/agent_rule.dart
//   lib/shared/providers/agent_rule_providers.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/database/novel_content_database.dart
//   lib/shared/models/novel.dart
//   lib/shared/components/reveric_text_field.dart
//   lib/shared/widgets/confirm_dialog.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/agent_rule.json
//   assets/translations/zh-CN/agent_rule.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/form.md
//   .agents/rules/text-input-ime.md
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/i18n.md
//   .agents/rules/error-handling.md
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/components/reveric_text_field.dart';
import '../../shared/database/novel_content_database.dart';
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/logger/app_logger.dart';
import '../../shared/models/agent_rule.dart';
import '../../shared/models/novel.dart';
import '../../shared/providers/agent_rule_providers.dart';
import '../../shared/providers/novel_providers.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/confirm_dialog.dart';
import '../../third/form/flutter_hook_form.dart';
import '../widgets/agent_edit_scaffold.dart';
import '../widgets/agent_rule_copy_sheet.dart';
import '../widgets/section_scaffold.dart';

final _log = AppLogger.forModule('MobileNovelAgentRule');

/// 作品级智能体规则列表页。读取 [agentRulesStreamProvider] 实时刷新，
/// 新建/编辑走 [_NovelAgentRuleEditPage] 全屏 push。
class MobileNovelAgentRuleManagePage extends ConsumerWidget {
  const MobileNovelAgentRuleManagePage({
    super.key,
    required this.novel,
    required this.databasePath,
  });

  final Novel novel;
  final String databasePath;

  AgentRule _newRule() {
    final now = DateTime.now();
    return AgentRule(
      id: '__new__${now.microsecondsSinceEpoch}',
      name: '',
      content: '',
      enabled: true,
      sortOrder: 0,
      createdAt: now,
      updatedAt: now,
      deletedAt: notDeletedSentinel,
    );
  }

  void _openEdit(BuildContext context, AgentRule rule) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _NovelAgentRuleEditPage(
          novel: novel,
          databasePath: databasePath,
          rule: rule,
        ),
      ),
    );
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    AgentRule rule,
  ) async {
    final confirmed = await confirmAgentDelete(
      context,
      title: context.t(LocaleKeys.commonDelete),
      message: context.t(
        LocaleKeys.agentRuleDeleteConfirm,
        namedArgs: {'name': rule.name},
      ),
    );
    if (confirmed != true) {
      return;
    }
    try {
      await ref
          .read(novelContentServiceProvider(databasePath))
          .deleteAgentRule(rule.id);
    } catch (error, stack) {
      _log.error('delete failed', error: error, stackTrace: stack);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.t(LocaleKeys.commonDeleteFailed))),
        );
      }
    }
  }

  Future<void> _copyFromOtherNovel(BuildContext context) async {
    final copied = await showMobileAgentRuleCopySheet(
      context,
      databasePath: databasePath,
      novelId: novel.id,
    );
    if (copied == null || copied == 0 || !context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          context.t(
            LocaleKeys.agentRuleCopySuccess,
            namedArgs: {'count': '$copied'},
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final rulesAsync = ref.watch(agentRulesStreamProvider(databasePath));
    final rules = rulesAsync.value ?? const <AgentRule>[];

    void create() => _openEdit(context, _newRule());

    return MobileManageScaffold(
      title: context.t(LocaleKeys.agentRuleTitle),
      onAdd: create,
      onSecondaryAction: () => unawaited(_copyFromOtherNovel(context)),
      secondaryActionLabel: context.t(LocaleKeys.agentRuleCopyFromNovel),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              RevericSpacing.x4l,
              RevericSpacing.md,
              RevericSpacing.x4l,
              RevericSpacing.sm,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                context.t(
                  LocaleKeys.agentRuleListHint,
                  namedArgs: {'title': novel.title},
                ),
                style: typo.uiSmall.copyWith(
                  color: colors.textMuted,
                  height: 1.6,
                ),
              ),
            ),
          ),
          Expanded(
            child: rulesAsync.isLoading && rules.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : rules.isEmpty
                ? MobileSectionEmptyState(
                    icon: RevericIcons.rule_outlined,
                    sectionLabel: context.t(LocaleKeys.agentRuleTitle),
                    hint: context.t(LocaleKeys.agentRuleEmpty),
                    actionLabel: context.t(LocaleKeys.commonCreate),
                    onCreate: create,
                  )
                : ListView.separated(
                    padding: mobileSectionListPadding,
                    itemCount: rules.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: RevericSpacing.sm),
                    itemBuilder: (context, index) {
                      final rule = rules[index];
                      return MobileSectionCard(
                        onTap: () => _openEdit(context, rule),
                        onDelete: () => _delete(context, ref, rule),
                        deleteLabel: context.t(LocaleKeys.commonDelete),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            RevericIcon(
                              RevericIcons.rule_outlined,
                              size: 18,
                              color: colors.accentWarm,
                            ),
                            const SizedBox(width: RevericSpacing.md),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          rule.name.isEmpty
                                              ? context.t(
                                                  LocaleKeys.commonUntitled,
                                                )
                                              : rule.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: typo.uiSemibold.copyWith(
                                            color: colors.textPrimary,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: RevericSpacing.sm),
                                      _RuleEnableChip(enabled: rule.enabled),
                                    ],
                                  ),
                                  const SizedBox(height: RevericSpacing.xs),
                                  MobileSectionPreviewText(
                                    preview: rule.content,
                                    emptyPlaceholder: context.t(
                                      LocaleKeys.agentRuleContentHint,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: RevericSpacing.sm),
                            const MobileSectionTrailingChevron(),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 启用/停用小徽章（对齐设计稿 EnableChip）。
class _RuleEnableChip extends StatelessWidget {
  const _RuleEnableChip({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final color = enabled ? colors.success : colors.textSubtle;
    return MobileSectionTagChip(
      label: context.t(
        enabled ? LocaleKeys.agentRuleEnabled : LocaleKeys.agentRuleDisabled,
      ),
      backgroundColor: color.withValues(alpha: 0.12),
      foregroundColor: color,
    );
  }
}

/// 规则编辑页：名称 + 内容 + 启用开关，保存走 [novelContentServiceProvider]（列表由 [agentRulesStreamProvider] 自动刷新）。
class _NovelAgentRuleEditPage extends HookConsumerWidget {
  const _NovelAgentRuleEditPage({
    required this.novel,
    required this.databasePath,
    required this.rule,
  });

  final Novel novel;
  final String databasePath;
  final AgentRule rule;

  bool get isNew => rule.id.startsWith('__new__');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saving = useState(false);

    final form = useForm<AgentRuleEditFields>(
      initialValues: {
        AgentRuleEditFields.name: rule.name,
        AgentRuleEditFields.content: rule.content,
        AgentRuleEditFields.enabled: rule.enabled,
      },
      keys: [rule.id],
    );

    final nameCtrl = useTextEditingController(text: rule.name);
    final contentCtrl = useTextEditingController(text: rule.content);
    final enabledValue = useState(rule.enabled);

    Future<void> save() async {
      if (!form.validate()) {
        return;
      }
      final content = contentCtrl.text.trim();
      if (content.length > agentRuleLongContentWarningThreshold) {
        final shouldSave = await showConfirmDialog(
          context,
          title: context.t(LocaleKeys.agentRuleTitle),
          message: context.t(
            LocaleKeys.agentRuleContentLongHint,
            namedArgs: {'threshold': '$agentRuleLongContentWarningThreshold'},
          ),
          confirmLabel: context.t(LocaleKeys.commonSave),
          variant: ConfirmDialogVariant.warning,
        );
        if (!shouldSave || !context.mounted) {
          return;
        }
      }
      saving.value = true;
      try {
        final name = nameCtrl.text.trim();
        final service = ref.read(novelContentServiceProvider(databasePath));
        final existingRules = await service.getAgentRules();
        final nameConflict = existingRules.any(
          (existing) => existing.name == name && existing.id != rule.id,
        );
        if (nameConflict) {
          throw AgentRuleNameConflictException(name);
        }
        final updated = rule.copyWith(
          name: name,
          content: content,
          enabled: enabledValue.value,
          updatedAt: DateTime.now(),
        );
        await service.upsertAgentRule(updated);
        if (context.mounted) {
          Navigator.of(context).pop();
        }
      } on AgentRuleNameConflictException catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                context.t(
                  LocaleKeys.agentRuleDuplicateName,
                  namedArgs: {'name': e.name},
                ),
              ),
            ),
          );
        }
      } catch (error, stack) {
        _log.error('save failed', error: error, stackTrace: stack);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.t(LocaleKeys.commonSaveFailed))),
          );
        }
      } finally {
        saving.value = false;
      }
    }

    final title = isNew ? context.t(LocaleKeys.commonCreate) : rule.name;

    return MobileAgentEditScaffold(
      title: title,
      saving: saving.value,
      canSave: !saving.value,
      onSave: save,
      children: [
        AgentEditHero(
          icon: RevericIcons.rule_outlined,
          title: title,
          subtitle: context.t(LocaleKeys.agentRuleEditSubtitle),
        ),
        const SizedBox(height: RevericSpacing.x2l),
        AgentEditEnableCard(
          value: enabledValue.value,
          onChanged: (v) {
            enabledValue.value = v;
            form.updateValue(AgentRuleEditFields.enabled, v, notify: false);
          },
        ),
        const SizedBox(height: RevericSpacing.x2l),
        HookedForm(
          form: form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AgentEditField(
                label: context.t(LocaleKeys.agentRuleName),
                child: HookedFormField<AgentRuleEditFields, String>(
                  fieldHook: AgentRuleEditFields.name,
                  notifyOnChange: true,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (value) => (value == null || value.trim().isEmpty)
                      ? context.t(LocaleKeys.agentRuleNameRequired)
                      : null,
                  builder: (value, onChanged, error) => RevericTextField(
                    controller: nameCtrl,
                    errorText: error,
                    onChanged: (v) => onChanged?.call(v),
                  ),
                ),
              ),
              const SizedBox(height: RevericSpacing.x2l),
              AgentEditField(
                label: context.t(LocaleKeys.agentRuleContent),
                hint: context.t(LocaleKeys.agentRuleNextChatHint),
                child: HookedFormField<AgentRuleEditFields, String>(
                  fieldHook: AgentRuleEditFields.content,
                  notifyOnChange: true,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (value) => (value == null || value.trim().isEmpty)
                      ? context.t(LocaleKeys.agentRuleContentRequired)
                      : null,
                  builder: (value, onChanged, error) => RevericTextField(
                    controller: contentCtrl,
                    multiline: true,
                    minLines: 6,
                    maxLines: 14,
                    keyboardType: TextInputType.multiline,
                    hintText: context.t(LocaleKeys.agentRuleContentHint),
                    errorText: error,
                    onChanged: (v) => onChanged?.call(v),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
