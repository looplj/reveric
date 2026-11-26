// 职责: AgentSkill 导入勾选对话框 — 展示扫描到的 SKILL.md 候选，勾选后确认导入。
//   并提供目录导入能力探测与 markdown 文件选择器类型组（对标素材导入）。
// 关联文件:
//   lib/shared/services/agent_skill_transfer.dart
//   lib/shared/localization/locale_keys.dart
//   lib/shared/theme/theme.dart
//   assets/translations/en/agent_skill.json
//   assets/translations/zh-CN/agent_skill.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/i18n.md
//   .agents/rules/icons.md
//   .agents/rules/code-style.md
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';

import '../components/reveric_button.dart';
import '../localization/app_localization.dart';
import '../localization/locale_keys.dart';
import '../services/agent_skill_transfer.dart';
import '../theme/theme.dart';

/// iOS / 移动端选文件时的类型组（需 UTI，对标素材导入）。
const agentSkillMarkdownTypeGroup = XTypeGroup(
  label: 'markdown',
  extensions: <String>['md'],
  uniformTypeIdentifiers: <String>[
    'net.daringfireball.markdown',
    'public.text',
  ],
);

/// 是否支持选择文件夹（iOS / Web 不支持，对标素材导入）。
bool agentSkillSupportsDirectoryImport() {
  if (kIsWeb) {
    return false;
  }
  return switch (defaultTargetPlatform) {
    TargetPlatform.android ||
    TargetPlatform.linux ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => true,
    TargetPlatform.fuchsia || TargetPlatform.iOS => false,
  };
}

/// 弹出导入勾选对话框。取消返回 `null`；确认返回勾选的候选。
/// 同名冲突默认不勾选，勾选后由导入流程先卸载再安装。
String agentSkillImportFeedback(
  BuildContext context,
  AgentSkillImportResult result,
) {
  if (result.failed == 0 && result.skipped == 0) {
    return context.t(
      LocaleKeys.agentSkillImportSuccess,
      namedArgs: {'imported': '${result.imported}'},
    );
  }
  return [
    context.t(
      LocaleKeys.agentSkillImportPartial,
      namedArgs: {
        'imported': '${result.imported}',
        'skipped': '${result.skipped}',
        'failed': '${result.failed}',
      },
    ),
    for (final failure in result.failures)
      '${failure.name} · ${context.t(switch (failure.reason) {
        AgentSkillImportFailureReason.too_large => LocaleKeys.agentSkillImportPackageTooLarge,
        AgentSkillImportFailureReason.unavailable => LocaleKeys.agentSkillImportSourceUnavailable,
        AgentSkillImportFailureReason.invalid => LocaleKeys.agentSkillImportPackageInvalid,
        AgentSkillImportFailureReason.failed => LocaleKeys.agentSkillImportFailed,
      })}',
  ].join('\n');
}

Future<List<AgentSkillImportCandidate>?> showAgentSkillImportDialog(
  BuildContext context, {
  required List<AgentSkillImportCandidate> candidates,
}) {
  assert(candidates.isNotEmpty, 'candidates must not be empty');
  final theme = RevericTheme.of(context);
  return showDialog<List<AgentSkillImportCandidate>>(
    context: context,
    builder: (dialogContext) {
      return RevericTheme(
        data: theme,
        child: _AgentSkillImportDialog(candidates: candidates),
      );
    },
  );
}

class _AgentSkillImportDialog extends StatefulWidget {
  const _AgentSkillImportDialog({required this.candidates});

  final List<AgentSkillImportCandidate> candidates;

  @override
  State<_AgentSkillImportDialog> createState() =>
      _AgentSkillImportDialogState();
}

class _AgentSkillImportDialogState extends State<_AgentSkillImportDialog> {
  late Set<String> _selectedPaths;

  @override
  void initState() {
    super.initState();
    // 默认勾选无同名冲突的项。
    _selectedPaths = {
      for (final c in widget.candidates)
        if (!c.nameConflict) c.filePath,
    };
  }

  Iterable<AgentSkillImportCandidate> get _importable =>
      widget.candidates.where((c) => !c.nameConflict);

  bool get _allImportableSelected {
    final importable = _importable.toList(growable: false);
    if (importable.isEmpty) {
      return false;
    }
    return importable.every((c) => _selectedPaths.contains(c.filePath));
  }

  void _toggleAll() {
    setState(() {
      final keptConflicts = {
        for (final candidate in widget.candidates)
          if (candidate.nameConflict &&
              _selectedPaths.contains(candidate.filePath))
            candidate.filePath,
      };
      if (_allImportableSelected) {
        _selectedPaths = keptConflicts;
      } else {
        _selectedPaths = {
          ...keptConflicts,
          for (final candidate in _importable) candidate.filePath,
        };
      }
    });
  }

  void _toggle(AgentSkillImportCandidate candidate) {
    setState(() {
      final next = Set<String>.from(_selectedPaths);
      if (!next.remove(candidate.filePath)) {
        next.add(candidate.filePath);
      }
      _selectedPaths = next;
    });
  }

  void _confirm() {
    final selected = widget.candidates
        .where((c) => _selectedPaths.contains(c.filePath))
        .toList(growable: false);
    if (selected.isEmpty) {
      return;
    }
    Navigator.of(context).pop(selected);
  }

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final selectedCount = _selectedPaths.length;
    final canImport = selectedCount > 0;

    return Dialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(RevericRadius.x2l),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(
              title: context.t(LocaleKeys.agentSkillImport),
              subtitle: context.t(LocaleKeys.agentSkillImportSubtitle),
              onClose: () => Navigator.of(context).maybePop(),
            ),
            Divider(
              height: RevericSizes.dividerThickness,
              color: colors.borderSubtle,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                RevericSpacing.x3l,
                RevericSpacing.x3l,
                RevericSpacing.x3l,
                RevericSpacing.x2l,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: RevericSpacing.md,
                    runSpacing: RevericSpacing.xs,
                    children: [
                      Text(
                        context.t(LocaleKeys.agentSkillImportSelectSkills),
                        style: typo.uiSmallSemibold.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                      Text(
                        context.t(
                          LocaleKeys.agentSkillImportSelectedCount,
                          namedArgs: {
                            'selected': '$selectedCount',
                            'total': '${widget.candidates.length}',
                          },
                        ),
                        style: typo.uiSmall.copyWith(color: colors.textMuted),
                      ),
                      RevericButton.text(
                        size: RevericButtonSize.compact,
                        label: context.t(
                          _allImportableSelected
                              ? LocaleKeys.agentSkillImportDeselectAll
                              : LocaleKeys.agentSkillImportSelectAll,
                        ),
                        onPressed: _toggleAll,
                      ),
                    ],
                  ),
                  const SizedBox(height: RevericSpacing.md),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.surfaceContainer,
                      borderRadius: BorderRadius.circular(RevericRadius.large),
                      border: Border.all(color: colors.borderSubtle),
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: 120,
                        maxHeight: 360,
                      ),
                      child: ListView.separated(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(
                          vertical: RevericSpacing.xs,
                        ),
                        itemCount: widget.candidates.length,
                        separatorBuilder: (_, _) => Divider(
                          height: RevericSizes.dividerThickness,
                          indent: RevericSpacing.x3l + 22,
                          color: colors.borderSubtle,
                        ),
                        itemBuilder: (context, index) {
                          final candidate = widget.candidates[index];
                          final selected = _selectedPaths.contains(
                            candidate.filePath,
                          );
                          return _SkillRow(
                            name: candidate.name,
                            category: [
                              candidate.category,
                              if (candidate.hasScripts)
                                context.t(
                                  LocaleKeys.agentSkillImportHasScripts,
                                ),
                            ].where((text) => text.isNotEmpty).join(' · '),
                            selected: selected,
                            conflict: candidate.nameConflict,
                            onTap: () => _toggle(candidate),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Divider(
              height: RevericSizes.dividerThickness,
              color: colors.borderSubtle,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                RevericSpacing.x3l,
                RevericSpacing.lg,
                RevericSpacing.x3l,
                RevericSpacing.x3l,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: Text(context.t(LocaleKeys.commonCancel)),
                  ),
                  const SizedBox(width: RevericSpacing.sm),
                  FilledButton(
                    onPressed: canImport ? _confirm : null,
                    child: Text(
                      context.t(
                        LocaleKeys.agentSkillImportConfirm,
                        namedArgs: {'count': '$selectedCount'},
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.subtitle,
    required this.onClose,
  });

  final String title;
  final String subtitle;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.x3l,
        RevericSpacing.x3l,
        RevericSpacing.x3l,
        RevericSpacing.lg,
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colors.accent.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(RevericRadius.large),
            ),
            child: RevericIcon(
              RevericIcons.upload,
              size: 18,
              color: colors.accent,
            ),
          ),
          const SizedBox(width: RevericSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: typo.uiSmallSemibold.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: typo.uiSmall.copyWith(color: colors.textMuted),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onClose,
            icon: RevericIcon(
              RevericIcons.close,
              size: 16,
              color: colors.textMuted,
            ),
            iconSize: RevericSizes.iconButtonSize,
            constraints: const BoxConstraints(
              minWidth: RevericSizes.iconButtonSize,
              minHeight: RevericSizes.iconButtonSize,
            ),
            padding: EdgeInsets.zero,
            splashRadius: RevericSizes.iconButtonSize / 2,
          ),
        ],
      ),
    );
  }
}

class _SkillRow extends StatelessWidget {
  const _SkillRow({
    required this.name,
    required this.category,
    required this.selected,
    required this.conflict,
    required this.onTap,
  });

  final String name;
  final String category;
  final bool selected;
  final bool conflict;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.lg,
          vertical: RevericSpacing.md,
        ),
        child: Row(
          children: [
            _CheckBox(selected: selected),
            const SizedBox(width: RevericSpacing.md),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: typo.uiSmall.copyWith(color: colors.textPrimary),
              ),
            ),
            if (conflict) ...[
              const SizedBox(width: RevericSpacing.sm),
              Text(
                context.t(LocaleKeys.agentSkillImportExists),
                style: typo.uiTiny.copyWith(color: colors.textMuted),
              ),
            ] else if (category.isNotEmpty) ...[
              const SizedBox(width: RevericSpacing.sm),
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: RevericSpacing.sm,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(RevericRadius.medium),
                    border: Border.all(color: colors.borderSubtle),
                  ),
                  child: Text(
                    category,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: typo.uiTiny.copyWith(color: colors.textMuted),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CheckBox extends StatelessWidget {
  const _CheckBox({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Container(
      width: 18,
      height: 18,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected ? colors.accent : Colors.transparent,
        border: Border.all(
          color: selected ? colors.accent : colors.borderInput,
          width: 1.5,
        ),
        borderRadius: BorderRadius.circular(RevericRadius.small),
      ),
      child: selected
          ? RevericIcon(RevericIcons.check, size: 12, color: colors.onAccent)
          : null,
    );
  }
}
