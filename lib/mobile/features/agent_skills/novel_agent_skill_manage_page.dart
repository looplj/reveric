// 职责: 移动端全局 AgentSkill 内容体 — 列表、编辑、启停、上传、删除与参考文档子页编辑。
// 关联文件:
//   lib/mobile/widgets/agent_edit_scaffold.dart
//   lib/mobile/widgets/section_scaffold.dart
//   lib/shared/models/agent_skill_reference.dart
//   lib/shared/models/novel_agent_skill.dart
//   lib/shared/providers/novel_agent_skill_providers.dart
//   lib/shared/services/agent_skill_transfer.dart
//   lib/mobile/features/agent_skills/import_flow.dart
//   lib/mobile/services/android_saf_directory_import.dart
//   lib/shared/widgets/agent_skill_export_dialog.dart
//   lib/mobile/features/agent_skills/installed_skill_detail_page.dart
//   lib/shared/components/reveric_text_field.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/agent_skill.json
//   assets/translations/zh-CN/agent_skill.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/form.md
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/i18n.md
//   .agents/rules/error-handling.md
import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../shared/components/reveric_text_field.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/logger/app_logger.dart';
import '../../../shared/models/agent_skill_reference.dart';
import '../../../shared/models/novel_agent_skill.dart';
import '../../../shared/providers/novel_agent_skill_providers.dart';
import '../../../shared/services/agent_skill_transfer.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/utils/text_input_composing.dart';
import '../../../shared/widgets/agent_skill_export_dialog.dart';
import 'import_flow.dart';
import '../../../third/form/flutter_hook_form.dart';
import '../../services/android_saf_directory_import.dart';
import '../../widgets/agent_edit_scaffold.dart';
import '../../widgets/section_scaffold.dart';
import 'installed_skill_detail_page.dart';

final _log = AppLogger.forModule('MobileNovelAgentSkill');

/// 全局 AgentSkill 内容体，直接嵌入 Setup 页的已安装 Tab。
class NovelInstalledSkillsView extends ConsumerWidget {
  const NovelInstalledSkillsView({super.key});

  Future<void> _openSkill(
    BuildContext context,
    WidgetRef ref, {
    NovelAgentSkillModel? skill,
  }) async {
    if (skill?.packageReadFailed ?? false) {
      _showTransferMessage(context, context.t(LocaleKeys.agentSkillLoadFailed));
      return;
    }
    if (skill == null || skill.sourceKind == AgentSkillSourceKind.novelLocal) {
      if (!context.mounted) {
        return;
      }
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => _NovelAgentSkillEditPage(skill: skill),
        ),
      );
      return;
    }

    if (!context.mounted) {
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (detailContext) => InstalledSkillDetailPage(
          skill: skill,
          onEdit: () async {
            // 编辑即脱离来源：转成本地技能后再进编辑页，
            // 之后不再接收官方/市场更新。
            final converted = await ref
                .read(installedAgentSkillsProvider.notifier)
                .convertToNovelLocal(skill.id);
            if (!detailContext.mounted) {
              return;
            }
            await Navigator.of(detailContext).pushReplacement<void, void>(
              MaterialPageRoute<void>(
                builder: (_) => _NovelAgentSkillEditPage(skill: converted),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    NovelAgentSkillModel skill,
  ) async {
    final confirmed = await confirmAgentDelete(
      context,
      title: context.t(LocaleKeys.commonDelete),
      message: context.t(
        LocaleKeys.agentSkillDeleteConfirm,
        namedArgs: {'name': skill.name},
      ),
    );
    if (confirmed != true) {
      return;
    }
    try {
      await ref.read(installedAgentSkillsProvider.notifier).remove(skill.id);
    } catch (error, stack) {
      _log.error('delete failed', error: error, stackTrace: stack);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.t(LocaleKeys.commonDeleteFailed))),
        );
      }
    }
  }

  Future<void> _exportSkills(
    BuildContext context,
    List<NovelAgentSkillModel> skills,
  ) async {
    if (skills.isEmpty) {
      _showTransferMessage(
        context,
        context.t(LocaleKeys.agentSkillExportEmpty),
      );
      return;
    }

    final request = await showAgentSkillExportDialog(context, entries: skills);
    if (request == null || !context.mounted) {
      return;
    }

    try {
      if (request.mode == AgentSkillExportMode.folder) {
        final transfer = const AgentSkillTransferService();
        if (defaultTargetPlatform == TargetPlatform.android) {
          final stage = await (await getTemporaryDirectory()).createTemp(
            'reveric_skill_export_',
          );
          final AndroidSafDirectoryExportResult? result;
          try {
            await transfer.exportToDirectory(
              dirPath: stage.path,
              entries: request.entries,
            );
            if (!context.mounted) {
              return;
            }
            result = await exportAndroidSkillDirectory(stage);
          } finally {
            await deleteAndroidDirectoryImport(stage.path);
          }
          if (!context.mounted || result == null) {
            return;
          }
          _showTransferMessage(
            context,
            context.t(
              LocaleKeys.agentSkillExportSuccess,
              namedArgs: {
                'count': '${request.entries.length}',
                'path': result.directoryName,
              },
            ),
          );
          return;
        }

        final dirPath = await getDirectoryPath(
          confirmButtonText: context.t(LocaleKeys.agentSkillExportSelectFolder),
        );
        if (!context.mounted || dirPath == null) {
          return;
        }
        final paths = await transfer.exportToDirectory(
          dirPath: dirPath,
          entries: request.entries,
        );
        if (!context.mounted) {
          return;
        }
        _showTransferMessage(
          context,
          context.t(
            LocaleKeys.agentSkillExportSuccess,
            namedArgs: {'count': '${paths.length}', 'path': dirPath},
          ),
        );
      } else {
        final directory = await getTemporaryDirectory();
        final zipPath = '${directory.path}/agent_skills.zip';
        await const AgentSkillTransferService().exportToZip(
          zipPath: zipPath,
          entries: request.entries,
        );
        if (!context.mounted) {
          return;
        }
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(zipPath)],
            fileNameOverrides: const ['agent_skills.zip'],
          ),
        );
      }
    } catch (error, stackTrace) {
      _log.error(
        'Export installed skills failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (context.mounted) {
        _showTransferMessage(
          context,
          context.t(LocaleKeys.agentSkillExportFailed),
        );
      }
    }
  }

  void _showTransferMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final skillsAsync = ref.watch(installedAgentSkillsProvider);
    final skills = skillsAsync.value ?? const <NovelAgentSkillModel>[];

    return ListView(
      padding: const EdgeInsets.only(
        top: RevericSpacing.lg,
        bottom: RevericSpacing.x5l,
      ),
      children: [
        _NovelSkillsSection(
          skills: skills,
          isLoading: skillsAsync.isLoading && skills.isEmpty,
          onTap: (skill) => unawaited(_openSkill(context, ref, skill: skill)),
          onDelete: (skill) => _delete(context, ref, skill),

          onCreate: () => unawaited(_openSkill(context, ref)),
          onImport: skillsAsync.isLoading
              ? null
              : () => unawaited(importMobileAgentSkills(context, ref)),
          onExport: () => unawaited(
            _exportSkills(
              context,
              skills.where((skill) => !skill.packageReadFailed).toList(),
            ),
          ),
        ),
      ],
    );
  }
}

/// 全局技能分区：空状态或可左滑删除、上传的卡片列表。
class _NovelSkillsSection extends StatelessWidget {
  const _NovelSkillsSection({
    required this.skills,
    required this.isLoading,
    required this.onTap,
    required this.onDelete,
    required this.onCreate,
    required this.onImport,
    required this.onExport,
  });

  final List<NovelAgentSkillModel> skills;
  final bool isLoading;
  final ValueChanged<NovelAgentSkillModel> onTap;
  final ValueChanged<NovelAgentSkillModel> onDelete;
  final VoidCallback onCreate;
  final VoidCallback? onImport;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.x4l),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  context.t(LocaleKeys.agentSkillTitle),
                  style: typo.uiSemibold.copyWith(color: colors.textSecondary),
                ),
              ),
              InkWell(
                onTap: onCreate,
                borderRadius: BorderRadius.circular(RevericRadius.pill),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: RevericSpacing.sm,
                    vertical: RevericSpacing.xxs,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RevericIcon(
                        RevericIcons.add,
                        size: 14,
                        color: colors.accentWarm,
                      ),
                      const SizedBox(width: RevericSpacing.xxs),
                      Text(
                        context.t(LocaleKeys.commonCreate),
                        style: typo.uiSmallSemibold.copyWith(
                          color: colors.accentWarm,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: RevericSpacing.sm),
        _ImportExportBar(onImport: onImport, onExport: onExport),
        const SizedBox(height: RevericSpacing.sm),
        if (isLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: RevericSpacing.x4l),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (skills.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.x4l),
            child: _NovelSkillsEmpty(onCreate: onCreate),
          )
        else
          ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.x4l),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: skills.length,
            separatorBuilder: (_, _) =>
                const SizedBox(height: RevericSpacing.sm),
            itemBuilder: (context, index) {
              final skill = skills[index];
              return MobileSectionCard(
                onTap: () => onTap(skill),
                onDelete: () => onDelete(skill),
                deleteLabel: context.t(LocaleKeys.commonDelete),

                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    RevericIcon(
                      RevericIcons.auto_awesome_outlined,
                      size: 18,
                      color: colors.accent,
                    ),
                    const SizedBox(width: RevericSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            skill.name.isEmpty
                                ? context.t(LocaleKeys.commonUntitled)
                                : skill.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: typo.uiSemibold.copyWith(
                              color: colors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: RevericSpacing.xs),
                          MobileSectionPreviewText(
                            preview: skill.packageReadFailed
                                ? context.t(LocaleKeys.agentSkillLoadFailed)
                                : skill.description,
                            emptyPlaceholder: context.t(
                              LocaleKeys.agentSkillDescription,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: RevericSpacing.sm),
                    if (!skill.packageReadFailed) ...[
                      _SkillEnableChip(enabled: skill.enabled),
                      const SizedBox(width: RevericSpacing.sm),
                      const MobileSectionTrailingChevron(),
                    ],
                  ],
                ),
              );
            },
          ),
      ],
    );
  }
}

/// 已安装技能的导入/导出入口；具体选择、校验与传输由上层编排。
class _ImportExportBar extends StatelessWidget {
  const _ImportExportBar({required this.onImport, required this.onExport});

  final VoidCallback? onImport;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: RevericSpacing.x4l),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: onImport,
              icon: const RevericIcon(RevericIcons.upload, size: 16),
              label: Text(context.t(LocaleKeys.agentSkillImportAction)),
            ),
          ),
          const SizedBox(width: RevericSpacing.sm),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: onExport,
              icon: const RevericIcon(RevericIcons.download, size: 16),
              label: Text(context.t(LocaleKeys.agentSkillExportAction)),
            ),
          ),
        ],
      ),
    );
  }
}

class _NovelSkillsEmpty extends StatelessWidget {
  const _NovelSkillsEmpty({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(RevericSpacing.x4l),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(RevericRadius.large),
        border: Border.all(color: colors.border, style: BorderStyle.solid),
      ),
      child: Column(
        children: [
          RevericIcon(
            RevericIcons.auto_awesome_outlined,
            size: 28,
            color: colors.textSubtle,
          ),
          const SizedBox(height: RevericSpacing.md),
          Text(
            context.t(LocaleKeys.agentSkillEmpty),
            textAlign: TextAlign.center,
            style: typo.uiSmall.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: RevericSpacing.lg),
          FilledButton(
            onPressed: onCreate,
            child: Text(context.t(LocaleKeys.commonCreate)),
          ),
        ],
      ),
    );
  }
}

/// 启用/停用小徽章（对齐设计稿 EnableChip）。
class _SkillEnableChip extends StatelessWidget {
  const _SkillEnableChip({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final color = enabled ? colors.success : colors.textSubtle;
    return MobileSectionTagChip(
      label: context.t(
        enabled ? LocaleKeys.agentSkillEnabled : LocaleKeys.agentRuleDisabled,
      ),
      backgroundColor: color.withValues(alpha: 0.12),
      foregroundColor: color,
    );
  }
}

enum _SkillField implements FieldSchema {
  name(validators: [RequiredValidator<String>()]),
  whenToUse(),
  description(),
  prompt(validators: [RequiredValidator<String>()]),
  enabled();

  const _SkillField({this.validators});

  @override
  final List<Validator<dynamic>>? validators;
}

/// 参考文档子页字段（文件名 + 内容）；校验放 widget 层 validator。
enum _RefEditField implements FieldSchema {
  fileName(),
  content();

  const _RefEditField();

  @override
  List<Validator<dynamic>>? get validators => null;
}

/// 技能编辑页：名称/调用名/使用时机/描述/提示词/启用，
/// 保存走 [installedAgentSkillsProvider]。
class _NovelAgentSkillEditPage extends HookConsumerWidget {
  const _NovelAgentSkillEditPage({this.skill});

  final NovelAgentSkillModel? skill;

  bool get isNew => skill == null;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(installedAgentSkillsProvider);
    final saving = useState(false);
    final existing = skill;

    final form = useForm<_SkillField>(
      initialValues: {
        _SkillField.name: existing?.name ?? '',
        _SkillField.whenToUse: existing?.whenToUse ?? '',
        _SkillField.description: existing?.description ?? '',
        _SkillField.prompt: existing?.prompt ?? '',
        _SkillField.enabled: existing?.enabled ?? true,
      },
      keys: [existing?.id ?? '__new__'],
    );

    final nameCtrl = useTextEditingController(text: existing?.name ?? '');
    final whenCtrl = useTextEditingController(text: existing?.whenToUse ?? '');
    final descCtrl = useTextEditingController(
      text: existing?.description ?? '',
    );
    final promptCtrl = useTextEditingController(text: existing?.prompt ?? '');
    final enabledValue = useState(existing?.enabled ?? true);
    final references = useState<List<AgentSkillReferenceFile>>(
      List<AgentSkillReferenceFile>.from(existing?.references ?? const []),
    );

    Future<void> openReference(int index) async {
      final result = await Navigator.of(context).push<_RefEditResult>(
        MaterialPageRoute<_RefEditResult>(
          builder: (_) =>
              _SkillReferenceEditPage(file: references.value[index]),
        ),
      );
      if (result == null) {
        return;
      }
      final next = List<AgentSkillReferenceFile>.from(references.value);
      if (result.deleted) {
        next.removeAt(index);
      } else if (result.file != null) {
        next[index] = result.file!;
      }
      references.value = next;
    }

    Future<void> addReference() async {
      final suggested = _nextReferenceFileNameStripped(references.value);
      final result = await Navigator.of(context).push<_RefEditResult>(
        MaterialPageRoute<_RefEditResult>(
          builder: (_) =>
              _SkillReferenceEditPage(file: null, suggestedName: suggested),
        ),
      );
      if (result == null || result.deleted || result.file == null) {
        return;
      }
      references.value = [...references.value, result.file!];
    }

    Future<void> save() async {
      if (!form.validate()) {
        return;
      }
      saving.value = true;
      try {
        final notifier = ref.read(installedAgentSkillsProvider.notifier);
        final name = nameCtrl.text.trim();
        if (isNew) {
          await notifier.createNovelLocalSkill(
            InstallSkillInput(
              sourceKind: AgentSkillSourceKind.novelLocal,
              name: name,
              whenToUse: whenCtrl.text.trim(),
              description: descCtrl.text.trim(),
              prompt: promptCtrl.text.trim(),
              references: AgentSkillReferences.sanitize(references.value),
              enabled: enabledValue.value,
            ),
          );
        } else {
          await notifier.updateSnapshotFields(
            existing!.copyWith(
              name: name,
              whenToUse: whenCtrl.text.trim(),
              description: descCtrl.text.trim(),
              prompt: promptCtrl.text.trim(),
              references: AgentSkillReferences.sanitize(references.value),
              enabled: enabledValue.value,
              executionBlockedReason: existing.executionBlockedReason,
            ),
          );
        }
        if (context.mounted) {
          Navigator.of(context).pop();
        }
      } on NovelSkillNameConflictException {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(context.t(LocaleKeys.agentSkillCallNameTaken)),
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

    final title = isNew
        ? context.t(LocaleKeys.commonCreate)
        : (existing?.name ?? '');

    return MobileAgentEditScaffold(
      title: title,
      saving: saving.value,
      canSave: !saving.value,
      onSave: save,
      children: [
        AgentEditHero(icon: RevericIcons.auto_awesome_outlined, title: title),
        const SizedBox(height: RevericSpacing.x2l),
        AgentEditEnableCard(
          value: enabledValue.value,
          onChanged: (v) {
            enabledValue.value = v;
            form.updateValue(_SkillField.enabled, v, notify: false);
          },
        ),
        const SizedBox(height: RevericSpacing.x2l),
        HookedForm(
          form: form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AgentEditField(
                label: context.t(LocaleKeys.agentSkillName),
                child: HookedFormField<_SkillField, String>(
                  fieldHook: _SkillField.name,
                  notifyOnChange: true,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (value) => (value == null || value.trim().isEmpty)
                      ? context.t(LocaleKeys.agentSkillNameRequired)
                      : null,
                  builder: (value, onChanged, error) => RevericTextField(
                    controller: nameCtrl,
                    autofocus: isNew,
                    errorText: error,
                    onChanged: (v) => onChanged?.call(v),
                  ),
                ),
              ),
              const SizedBox(height: RevericSpacing.x2l),
              AgentEditField(
                label: context.t(LocaleKeys.agentSkillWhenToUse),
                hint: context.t(LocaleKeys.agentSkillWhenToUseHelp),
                child: HookedFormField<_SkillField, String>(
                  fieldHook: _SkillField.whenToUse,
                  notifyOnChange: true,
                  builder: (value, onChanged, error) => RevericTextField(
                    controller: whenCtrl,
                    multiline: true,
                    minLines: 2,
                    maxLines: 4,
                    keyboardType: TextInputType.multiline,
                    hintText: context.t(LocaleKeys.agentSkillWhenToUseHint),
                    errorText: error,
                    onChanged: (v) => onChanged?.call(v),
                  ),
                ),
              ),
              const SizedBox(height: RevericSpacing.x2l),
              AgentEditField(
                label: context.t(LocaleKeys.agentSkillDescription),
                child: HookedFormField<_SkillField, String>(
                  fieldHook: _SkillField.description,
                  notifyOnChange: true,
                  builder: (value, onChanged, error) => RevericTextField(
                    controller: descCtrl,
                    multiline: true,
                    minLines: 2,
                    maxLines: 4,
                    keyboardType: TextInputType.multiline,
                    errorText: error,
                    onChanged: (v) => onChanged?.call(v),
                  ),
                ),
              ),
              const SizedBox(height: RevericSpacing.x2l),
              AgentEditField(
                label: context.t(LocaleKeys.agentSkillPrompt),
                hint: context.t(LocaleKeys.agentSkillPromptHint),
                child: HookedFormField<_SkillField, String>(
                  fieldHook: _SkillField.prompt,
                  notifyOnChange: true,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (value) => (value == null || value.trim().isEmpty)
                      ? context.t(LocaleKeys.agentSkillPromptRequired)
                      : null,
                  builder: (value, onChanged, error) => RevericTextField(
                    controller: promptCtrl,
                    multiline: true,
                    minLines: 6,
                    maxLines: 14,
                    keyboardType: TextInputType.multiline,
                    errorText: error,
                    onChanged: (v) => onChanged?.call(v),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: RevericSpacing.x2l),
        AgentEditField(
          label: context.t(LocaleKeys.agentSkillReferences),
          trailing: references.value.length < AgentSkillReferences.maxCount
              ? InkWell(
                  onTap: addReference,
                  borderRadius: BorderRadius.circular(RevericRadius.pill),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: RevericSpacing.sm,
                      vertical: RevericSpacing.xxs,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        RevericIcon(
                          RevericIcons.add,
                          size: 14,
                          color: RevericTheme.colorsOf(context).accentWarm,
                        ),
                        const SizedBox(width: RevericSpacing.xxs),
                        Text(
                          context.t(LocaleKeys.agentSkillReferencesAdd),
                          style: RevericTheme.typographyOf(context)
                              .uiSmallSemibold
                              .copyWith(
                                color: RevericTheme.colorsOf(
                                  context,
                                ).accentWarm,
                              ),
                        ),
                      ],
                    ),
                  ),
                )
              : null,
          child: _MobileReferenceList(
            references: references.value,
            onOpen: openReference,
          ),
        ),
      ],
    );
  }
}

/// 移动端编辑页的参考文档行列表：空态占位或可点击进入子页的文件行。
class _MobileReferenceList extends StatelessWidget {
  const _MobileReferenceList({required this.references, required this.onOpen});

  final List<AgentSkillReferenceFile> references;
  final ValueChanged<int> onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    if (references.isEmpty) {
      return Text(
        context.t(LocaleKeys.agentSkillReferencesEmpty),
        style: typo.uiSmall.copyWith(color: colors.textMuted),
      );
    }
    return Column(
      children: [
        for (var i = 0; i < references.length; i++) ...[
          if (i > 0) const SizedBox(height: RevericSpacing.sm),
          InkWell(
            onTap: () => onOpen(i),
            borderRadius: BorderRadius.circular(RevericRadius.large),
            child: Container(
              height: RevericSizes.fieldHeight,
              padding: const EdgeInsets.symmetric(
                horizontal: RevericSpacing.lg,
              ),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(RevericRadius.large),
                border: Border.all(color: colors.borderInput),
              ),
              child: Row(
                children: [
                  RevericIcon(
                    RevericIcons.description_outlined,
                    size: 17,
                    color: colors.accent,
                  ),
                  const SizedBox(width: RevericSpacing.sm),
                  Expanded(
                    child: Text(
                      _referenceLabel(references[i].path),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typo.uiSmall.copyWith(color: colors.textPrimary),
                    ),
                  ),
                  RevericIcon(
                    RevericIcons.chevron_right,
                    size: 18,
                    color: colors.textSubtle,
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

String _referenceLabel(String path) {
  return path.startsWith(AgentSkillReferences.relativeDirPrefix)
      ? path.substring(AgentSkillReferences.relativeDirPrefix.length)
      : path;
}

/// 生成不冲突的默认参考文档文件名（去前缀，如 `ref-1.md`）。
String _nextReferenceFileNameStripped(List<AgentSkillReferenceFile> current) {
  final existing = current.map((f) => _referenceLabel(f.path)).toSet();
  var index = current.length + 1;
  while (existing.contains('ref-$index.md')) {
    index += 1;
  }
  return 'ref-$index.md';
}

/// 参考文档子页返回结果：保存后的文件或删除信号。
class _RefEditResult {
  const _RefEditResult.saved(this.file) : deleted = false;
  const _RefEditResult.deleted() : file = null, deleted = true;

  final AgentSkillReferenceFile? file;
  final bool deleted;
}

/// 移动端参考文档编辑子页：文件名 + 内容；[file] 为 null 表示新建。
/// 新建时用 [suggestedName]（如 `ref-1.md`）预填一个合法文件名。
class _SkillReferenceEditPage extends HookWidget {
  const _SkillReferenceEditPage({required this.file, this.suggestedName});

  final AgentSkillReferenceFile? file;
  final String? suggestedName;

  bool get isNew => file == null;

  @override
  Widget build(BuildContext context) {
    final initialName = file != null
        ? _referenceLabel(file!.path)
        : (suggestedName ?? '');
    final form = useForm<_RefEditField>(
      initialValues: {
        _RefEditField.fileName: initialName,
        _RefEditField.content: file?.content ?? '',
      },
      listen: false,
    );
    final nameCtrl = useTextEditingController(text: initialName);
    final nameFocus = useFocusNode();
    final contentCtrl = useTextEditingController(text: file?.content ?? '');
    final contentFocus = useFocusNode();

    Future<void> save() async {
      // 提交时把 controller 文本同步进 form 再统一校验；错误由各字段 inline 展示。
      syncFormFieldsFromControllersBeforeValidate(
        form: form,
        fields: {
          _RefEditField.fileName: nameCtrl,
          _RefEditField.content: contentCtrl,
        },
      );
      if (!form.validate()) {
        return;
      }
      final raw = nameCtrl.text.trim();
      final path = '${AgentSkillReferences.relativeDirPrefix}$raw';
      Navigator.of(context).pop(
        _RefEditResult.saved(
          AgentSkillReferenceFile(path: path, content: contentCtrl.text),
        ),
      );
    }

    final title = isNew
        ? context.t(LocaleKeys.agentSkillReferencesNew)
        : (initialName.isEmpty
              ? context.t(LocaleKeys.agentSkillReferencesNew)
              : initialName);

    return MobileAgentEditScaffold(
      title: title,
      saving: false,
      canSave: true,
      onSave: save,
      children: [
        HookedForm(
          form: form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AgentEditField(
                label: context.t(LocaleKeys.agentSkillReferencesFileName),
                child: HookedFormField<_RefEditField, String>(
                  fieldHook: _RefEditField.fileName,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (value) {
                    final raw = (value ?? '').trim();
                    final valid =
                        raw.isNotEmpty &&
                        AgentSkillReferences.isValidRelativePath(
                          '${AgentSkillReferences.relativeDirPrefix}$raw',
                        );
                    return valid
                        ? null
                        : context.t(
                            LocaleKeys.agentSkillReferencesFileNameInvalid,
                          );
                  },
                  builder: (_, _, error) => RevericTextField(
                    controller: nameCtrl,
                    focusNode: nameFocus,
                    autofocus: isNew,
                    errorText: error,
                    hintText: context.t(
                      LocaleKeys.agentSkillReferencesFileName,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: RevericSpacing.x2l),
              AgentEditField(
                label: context.t(LocaleKeys.agentSkillReferencesContent),
                child: HookedFormField<_RefEditField, String>(
                  fieldHook: _RefEditField.content,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (value) => (value == null || value.trim().isEmpty)
                      ? context.t(
                          LocaleKeys.agentSkillReferencesContentRequired,
                        )
                      : null,
                  builder: (_, _, error) => RevericTextField(
                    controller: contentCtrl,
                    focusNode: contentFocus,
                    errorText: error,
                    multiline: true,
                    minLines: 10,
                    maxLines: 24,
                    keyboardType: TextInputType.multiline,
                    hintText: context.t(
                      LocaleKeys.agentSkillReferencesContentHint,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (!isNew) ...[
          const SizedBox(height: RevericSpacing.x3l),
          AgentEditDeleteButton(
            label: context.t(LocaleKeys.commonDelete),
            onTap: () =>
                Navigator.of(context).pop(const _RefEditResult.deleted()),
          ),
        ],
      ],
    );
  }
}
