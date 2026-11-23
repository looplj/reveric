// 职责: AgentSkill Setup 面板 —— 全局技能管理、目录安装与导入导出。
//   小说页保留 novelId 入参以兼容页面导航，但已安装与目录技能始终使用 global scope。
//   已安装 Tab 支持本地文件夹、Markdown 文件和公开仓库链接导入，以及目录 / ZIP 导出。
// 关联文件:
//   lib/shared/components/reveric_dialog.dart
//   lib/shared/components/reveric_button.dart
//   lib/shared/providers/novel_agent_skill_providers.dart
//   lib/shared/providers/agent_skill_catalog_providers.dart
//   lib/shared/services/agent_skill_transfer.dart
//   lib/shared/widgets/agent_skill_export_dialog.dart
//   lib/shared/widgets/agent_skill_import_dialog.dart
//   lib/shared/models/novel_agent_skill.dart
//   lib/shared/components/reveric_switch.dart
//   lib/shared/components/reveric_context_menu.dart
//   lib/shared/components/reveric_search_field.dart
//   lib/shared/widgets/confirm_dialog.dart
//   lib/shared/components/reveric_text_field.dart
//   lib/shared/widgets/guide/trigger.dart
//   lib/shared/localization/locale_keys.dart
//   lib/shared/logger/app_logger.dart
//   lib/desktop/features/agent_skills/source_card.dart
//   lib/desktop/features/agent_skills/catalog_filter_bar.dart
//   lib/desktop/features/agent_skills/official_catalog_tab.dart
//   lib/desktop/features/agent_skills/marketplace_catalog_tab.dart
//   lib/desktop/features/agent_skills/catalog_detail_panel.dart
//   lib/desktop/features/agent_skills/installed_skill_detail_panel.dart
//   lib/desktop/widgets/desktop_window_frame.dart
//   assets/translations/en/agent_skill.json
//   assets/translations/zh-CN/agent_skill.json
//   assets/translations/en/onboarding.json
//   assets/translations/zh-CN/onboarding.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/i18n.md
//   .agents/rules/icons.md
//   .agents/rules/error-handling.md
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
import 'dart:async';
import 'dart:io' show Directory, Platform;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../shared/components/reveric_button.dart';
import '../../../shared/components/reveric_context_menu.dart';
import '../../../shared/components/reveric_more_menu_button.dart';
import '../../../shared/components/reveric_switch.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/logger/app_logger.dart';
import '../../../shared/models/dictionary_fallbacks.dart';
import '../../../shared/models/novel_agent_skill.dart';
import '../../../shared/providers/agent_skill_catalog_providers.dart';
import '../../../shared/providers/novel_agent_skill_providers.dart';
import '../../../shared/services/agent_skill_transfer.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/agent_skill_export_dialog.dart';
import '../../../shared/widgets/agent_skill_import_dialog.dart';
import '../../../shared/widgets/agent_skill_import_source_form.dart';
import '../../../shared/widgets/confirm_dialog.dart';
import '../../../shared/widgets/guide/tour.dart';
import '../../../shared/widgets/guide/trigger.dart';
import '../../widgets/desktop_window_frame.dart';
import 'catalog_detail_panel.dart';
import 'installed_skill_detail_panel.dart';
import 'marketplace_catalog_tab.dart';
import 'official_catalog_tab.dart';
import '../../../shared/components/reveric_dialog.dart';

final _log = AppLogger.forModule('SkillSetupPanel');

/// 本地档类别候选；与 [kFallbackSkillCategories] 同源，供编辑态离线兜底。
const List<String> kLocalSkillCategories = kFallbackSkillCategories;

enum _SkTab { installed, official, market }

_SkTab _defaultTab(bool home) => _SkTab.installed;

class SkillSetupPanel extends HookConsumerWidget {
  const SkillSetupPanel({
    super.key,
    this.novelId,
    this.novelTitle,
    this.headerTrailingInset = 0,
    this.headerGestureExclusionKey,
    this.onCreateInstalledSkill,
    this.onOpenInstalledSkill,
    this.onBack,
  });

  /// null = Home 入口；非 null = 小说编辑器入口。技能操作不依赖此值。
  final String? novelId;
  final String? novelTitle;
  final double headerTrailingInset;
  final GlobalKey? headerGestureExclusionKey;
  final VoidCallback? onCreateInstalledSkill;
  final ValueChanged<NovelAgentSkillModel>? onOpenInstalledSkill;
  final VoidCallback? onBack;

  bool get isHome => novelId == null;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final tab = useState(_defaultTab(isHome));
    final dialog = useState<_SkDialog?>(null);
    // 非 null 时整页切换为官方/市场只读详情(长提示词不适合 Dialog)。
    final catalogDetail = useState<AgentSkillCatalogDetailTarget?>(null);
    // 非 null 时整页切换为已安装技能只读详情。
    final installedDetail = useState<NovelAgentSkillModel?>(null);
    final listGuideKey = useMemoized(GlobalKey.new);
    final marketGuideKey = useMemoized(GlobalKey.new);
    final guideReady =
        catalogDetail.value == null && installedDetail.value == null;
    useAutoGuideTour(
      ref: ref,
      tourId: GuideTourId.skills,
      ready: guideReady,
      keys: [guideReady],
      buildSteps: (ctx) => [
        GuideStep(
          id: 'skills_list',
          targetKey: listGuideKey,
          icon: RevericIcons.layers_outlined,
          title: ctx.t(LocaleKeys.onboardingGuideSkillsListTitle),
          description: ctx.t(LocaleKeys.onboardingGuideSkillsListBody),
          onBeforeEnter: () {
            tab.value = _SkTab.installed;
          },
        ),
        GuideStep(
          id: 'skills_market',
          targetKey: marketGuideKey,
          icon: RevericIcons.storefront,
          title: ctx.t(LocaleKeys.onboardingGuideSkillsMarketTitle),
          description: ctx.t(LocaleKeys.onboardingGuideSkillsMarketBody),
          onBeforeEnter: () {
            tab.value = _SkTab.market;
          },
        ),
      ],
    );
    // 非 null 时整页切换为上传表单。

    final installed =
        ref.watch(installedAgentSkillsProvider).value ??
        const <NovelAgentSkillModel>[];
    // Tab 角标用未过滤全量列表长度;与各 Tab 默认「全部」视图一致。
    final unfiltered = agentSkillCatalogFilter();
    final officialCount =
        ref
            .watch(officialAgentSkillsProvider(unfiltered))
            .value
            ?.agentSkills
            .length ??
        0;
    final counts = <_SkTab, int>{
      _SkTab.installed: installed.length,
      _SkTab.official: officialCount,
    };

    Future<void> flash(String msg) async {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }

    // 对话框由动作设置 dialog.value 后通过 useEffect 弹出,关闭后清空。
    // 注意: useEffect 在 initHook/didUpdateHook 阶段同步执行,而 showDialog
    // 内部会调用 debugCheckHasMaterialLocalizations -> Localizations.of,
    // 后者依赖 InheritedWidget,在 HookState.initState 期间被禁止,会触发
    // '!_debugIsInitHook' 断言。因此必须把弹窗推迟到当前帧结束之后。
    useEffect(() {
      final d = dialog.value;
      if (d == null) {
        return null;
      }
      Future<void>? future;
      bool disposed = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (disposed) {
          return;
        }
        future = () async {
          switch (d) {
            case _SkRevokedDialog(:final item):
              await _showRevokedDialog(context, item);
          }
          dialog.value = null;
        }();
      });
      return () {
        disposed = true;
        future?.ignore();
      };
    }, [dialog.value]);

    Future<List<AgentSkillImportCandidate>?> selectSkillsForImport(
      List<NovelAgentSkillModel> existing, {
      String initialUrl = '',
    }) async {
      const transfer = AgentSkillTransferService();
      final candidates =
          await showRevericDialog<List<AgentSkillImportCandidate>>(
            context: context,
            builder: (dialogContext) => RevericDialog.panel(
              title: Text(dialogContext.t(LocaleKeys.agentSkillImport)),
              content: AgentSkillImportSourceForm(
                initialUrl: initialUrl,
                existingNames: existing
                    .map((skill) => skill.name.trim())
                    .toSet(),
                pickDirectory: () async {
                  final path = await getDirectoryPath();
                  if (path == null) {
                    return null;
                  }
                  return transfer.discoverInDirectory(
                    dirPath: path,
                    existing: existing,
                  );
                },
                pickFiles: () async {
                  final files = await openFiles(
                    acceptedTypeGroups: const [agentSkillMarkdownTypeGroup],
                  );
                  if (files.isEmpty) {
                    return null;
                  }
                  return [
                    for (final file in files)
                      transfer.parseSelectedMarkdown(
                        content: await file.readAsString(),
                        fileName: file.path,
                        existing: existing,
                      ),
                  ];
                },
                onDiscovered: (items) => Navigator.of(dialogContext).pop(items),
              ),
              actions: [
                RevericButton.text(
                  label: dialogContext.t(LocaleKeys.commonCancel),
                  onPressed: () => Navigator.of(dialogContext).pop(),
                ),
              ],
            ),
          );
      if (!context.mounted || candidates == null) {
        return null;
      }
      return showAgentSkillImportDialog(context, candidates: candidates);
    }

    // 导入到全局技能：技能应用全局唯一,name 即工具名。
    Future<void> importInstalledSkills({String initialUrl = ''}) async {
      try {
        final selected = await selectSkillsForImport(
          installed,
          initialUrl: initialUrl,
        );
        if (selected == null || !context.mounted) {
          return;
        }

        const transfer = AgentSkillTransferService();
        final result = await transfer.importCandidates(
          candidates: selected,
          notifier: ref.read(installedAgentSkillsProvider.notifier),
          existing: installed,
        );
        if (!context.mounted) {
          return;
        }
        if (result.failed > 0 || result.skipped > 0) {
          await flash(
            context.t(
              LocaleKeys.agentSkillImportPartial,
              namedArgs: {
                'imported': '${result.imported}',
                'skipped': '${result.skipped}',
                'failed': '${result.failed}',
              },
            ),
          );
        } else {
          await flash(
            context.t(
              LocaleKeys.agentSkillImportSuccess,
              namedArgs: {'imported': '${result.imported}'},
            ),
          );
        }
      } catch (error, stackTrace) {
        _log.error(
          'Import installed skills failed',
          error: error,
          stackTrace: stackTrace,
        );
        if (!context.mounted) {
          return;
        }
        await flash(context.t(LocaleKeys.agentSkillImportFailed));
      }
    }

    // 批量导出：弹窗勾选技能 + 选择格式，再执行。
    Future<void> exportSkills(List<NovelAgentSkillModel> entries) async {
      if (entries.isEmpty) {
        await flash(context.t(LocaleKeys.agentSkillExportEmpty));
        return;
      }
      if (!context.mounted) return;
      final request = await showAgentSkillExportDialog(
        context,
        entries: entries,
      );
      if (request == null || !context.mounted) return;
      final selected = request.entries;

      try {
        if (request.mode == AgentSkillExportMode.folder) {
          final dirPath = await getDirectoryPath(
            confirmButtonText: context.t(
              LocaleKeys.agentSkillExportSelectFolder,
            ),
          );
          if (!context.mounted || dirPath == null) return;
          final paths = await const AgentSkillTransferService()
              .exportToDirectory(dirPath: dirPath, entries: selected);
          if (!context.mounted) return;
          await flash(
            context.t(
              LocaleKeys.agentSkillExportSuccess,
              namedArgs: {'count': '${paths.length}', 'path': dirPath},
            ),
          );
        } else {
          // ZIP：桌面用 getSaveLocation，移动端用 share_plus 分享。
          if (Platform.isIOS || Platform.isAndroid) {
            final dir = await _temporaryZipDir();
            final zipPath = '${dir.path}/agent_skills.zip';
            await const AgentSkillTransferService().exportToZip(
              zipPath: zipPath,
              entries: selected,
            );
            if (!context.mounted) return;
            await SharePlus.instance.share(
              ShareParams(
                files: [XFile(zipPath)],
                fileNameOverrides: ['agent_skills.zip'],
              ),
            );
          } else {
            final location = await getSaveLocation(
              suggestedName: 'agent_skills.zip',
            );
            if (!context.mounted || location == null) return;
            final zipPath = location.path;
            await const AgentSkillTransferService().exportToZip(
              zipPath: zipPath,
              entries: selected,
            );
            if (!context.mounted) return;
            await flash(
              context.t(
                LocaleKeys.agentSkillExportSuccess,
                namedArgs: {'count': '${selected.length}', 'path': zipPath},
              ),
            );
          }
        }
      } catch (error, stackTrace) {
        _log.error('Export failed', error: error, stackTrace: stackTrace);
        if (!context.mounted) return;
        await flash(context.t(LocaleKeys.agentSkillExportFailed));
      }
    }

    Future<void> exportInstalledSkills() async {
      await exportSkills(installed);
    }

    // 全局技能承接了原「技能库」的职责；从条目上传时保留当前内容作为预填。

    if (catalogDetail.value != null) {
      return AgentSkillCatalogDetailPanel(
        target: catalogDetail.value!,
        onBack: () => catalogDetail.value = null,
      );
    }

    if (installedDetail.value != null) {
      final detailSkill = installedDetail.value!;
      return InstalledSkillDetailPanel(
        skill: detailSkill,
        headerTrailingInset: headerTrailingInset,
        headerGestureExclusionKey: headerGestureExclusionKey,
        onBack: () => installedDetail.value = null,
        onEdit: onOpenInstalledSkill == null
            ? null
            : () async {
                // 编辑即脱离来源：转成本地技能后再进编辑面板，
                // 之后不再接收官方/市场更新。
                final converted = await ref
                    .read(installedAgentSkillsProvider.notifier)
                    .convertToNovelLocal(detailSkill.id);
                installedDetail.value = null;
                onOpenInstalledSkill!(converted);
              },
      );
    }

    return Material(
      color: colors.canvas,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(
            context: context,
            colors: colors,
            typo: typo,
            tab: tab.value,
            onCreate: tab.value == _SkTab.installed
                ? onCreateInstalledSkill
                : null,
            createLabelKey: LocaleKeys.commonCreate,
            onImport: tab.value == _SkTab.installed
                ? importInstalledSkills
                : null,
            onExport: tab.value == _SkTab.installed
                ? exportInstalledSkills
                : null,
            onBack: onBack,
          ),
          _buildTabs(
            context: context,
            colors: colors,
            typo: typo,
            tab: tab,
            counts: counts,
          ),
          if (tab.value == _SkTab.official || tab.value == _SkTab.market)
            // official / market tab 各自渲染 CatalogFilterBar,此处不再重复过滤栏。
            const SizedBox.shrink()
          else
            Divider(
              height: RevericSizes.dividerThickness,
              color: colors.borderSubtle,
            ),
          Expanded(
            child: switch (tab.value) {
              _SkTab.installed => KeyedSubtree(
                key: listGuideKey,
                child: _InstalledList(
                  items: installed,
                  onToggle: (id) async {
                    await ref
                        .read(installedAgentSkillsProvider.notifier)
                        .toggleEnabled(id);
                  },
                  onAction: (action, item) async {
                    switch (action) {
                      case _RowAction.remove:
                        final confirmed = await showConfirmDialog(
                          context,
                          title: context.t(LocaleKeys.commonDelete),
                          message: context.t(
                            LocaleKeys.agentSkillDeleteConfirm,
                            namedArgs: {'name': item.name},
                          ),
                          confirmLabel: context.t(LocaleKeys.agentSkillRemove),
                          variant: ConfirmDialogVariant.error,
                        );
                        if (!confirmed) {
                          return;
                        }
                        await ref
                            .read(installedAgentSkillsProvider.notifier)
                            .remove(item.id);
                        if (!context.mounted) {
                          return;
                        }
                        await flash(
                          context.t(
                            LocaleKeys.agentSkillToastRemoved,
                            namedArgs: {'name': item.name},
                          ),
                        );
                      case _RowAction.revoked:
                        dialog.value = _SkDialog.revoked(item: item);
                    }
                  },
                  onCreate: onCreateInstalledSkill,
                  onOpen: onOpenInstalledSkill,
                  onOpenDetail: (item) {
                    installedDetail.value = item;
                  },
                ),
              ),
              _SkTab.official => OfficialCatalogTab(
                flash: flash,
                onOpenDetail: (skill) {
                  catalogDetail.value = OfficialSkillCatalogDetail(skill);
                },
              ),
              _SkTab.market => KeyedSubtree(
                key: marketGuideKey,
                child: MarketplaceCatalogTab(
                  onImport: (url) => importInstalledSkills(initialUrl: url),
                ),
              ),
            },
          ),
        ],
      ),
    );
  }

  Widget _buildHeader({
    required BuildContext context,
    required RevericColors colors,
    required RevericTypography typo,
    required _SkTab tab,
    required VoidCallback? onCreate,
    required String createLabelKey,
    VoidCallback? onImport,
    VoidCallback? onExport,
    VoidCallback? onBack,
  }) {
    return Container(
      key: headerGestureExclusionKey,
      height: DesktopWindowFrame.titleBarHeight,
      padding: EdgeInsetsDirectional.only(
        start: RevericSpacing.x2l,
        end: RevericSpacing.lg + headerTrailingInset,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          if (onBack != null) ...[
            IconButton(
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: onBack,
              icon: RevericIcon(
                RevericIcons.arrow_back,
                size: 18,
                color: colors.textMuted,
              ),
            ),
            const SizedBox(width: RevericSpacing.xs),
          ],
          RevericIcon(
            RevericIcons.layers_outlined,
            size: 18,
            color: colors.accent,
          ),
          const SizedBox(width: RevericSpacing.sm),
          Expanded(
            child: Text(
              context.t(
                isHome
                    ? LocaleKeys.agentSkillSetupHomeTitle
                    : LocaleKeys.agentSkillSetupTitle,
              ),
              style: typo.heading2.copyWith(color: colors.textPrimary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onImport != null) ...[
            Tooltip(
              message: context.t(LocaleKeys.agentSkillImportHint),
              child: OutlinedButton.icon(
                onPressed: onImport,
                icon: RevericIcon(RevericIcons.upload, size: 16),
                label: Text(context.t(LocaleKeys.agentSkillImportAction)),
              ),
            ),
            const SizedBox(width: RevericSpacing.sm),
          ],
          if (onExport != null) ...[
            OutlinedButton.icon(
              onPressed: onExport,
              icon: RevericIcon(RevericIcons.download, size: 16),
              label: Text(context.t(LocaleKeys.agentSkillExportAction)),
            ),
            const SizedBox(width: RevericSpacing.sm),
          ],
          if (onCreate != null)
            FilledButton.icon(
              onPressed: onCreate,
              icon: RevericIcon(RevericIcons.add, size: 14),
              label: Text(context.t(createLabelKey)),
            ),
        ],
      ),
    );
  }

  Widget _buildTabs({
    required BuildContext context,
    required RevericColors colors,
    required RevericTypography typo,
    required ValueNotifier<_SkTab> tab,
    required Map<_SkTab, int> counts,
  }) {
    const tabs = _SkTab.values;
    return Container(
      padding: EdgeInsetsDirectional.only(
        start: RevericSpacing.x5l,
        end: RevericSpacing.x5l,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          for (final t in tabs)
            _buildTabItem(context, colors, typo, tab, t, counts[t] ?? 0),
        ],
      ),
    );
  }

  Widget _buildTabItem(
    BuildContext context,
    RevericColors colors,
    RevericTypography typo,
    ValueNotifier<_SkTab> tab,
    _SkTab t,
    int count,
  ) {
    final active = tab.value == t;
    final label = switch (t) {
      _SkTab.installed => context.t(LocaleKeys.agentSkillTabInstalled),
      _SkTab.official => context.t(LocaleKeys.agentSkillTabOfficial),
      _SkTab.market => context.t(LocaleKeys.agentSkillTabMarket),
    };
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: RevericSpacing.xs),
      child: GestureDetector(
        onTap: () => tab.value = t,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: RevericSpacing.xs,
            vertical: RevericSpacing.lg,
          ),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                width: 2,
                color: active ? colors.accent : Colors.transparent,
              ),
            ),
          ),
          child: Row(
            children: [
              Text(
                label,
                style: (active ? typo.uiSemibold : typo.uiMedium).copyWith(
                  color: active ? colors.textPrimary : colors.textMuted,
                ),
              ),
              if (t != _SkTab.market) ...[
                const SizedBox(width: RevericSpacing.xs),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: active
                        ? colors.accent.withValues(alpha: 0.16)
                        : colors.surfaceDim,
                    borderRadius: BorderRadius.circular(RevericRadius.pill),
                  ),
                  child: Text(
                    '$count',
                    style: typo.uiTiny.copyWith(
                      color: active ? colors.accent : colors.textSubtle,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ── 对话框 ─────────────────────────────────────────────────────────────

  Future<void> _showRevokedDialog(
    BuildContext context,
    NovelAgentSkillModel item,
  ) async {
    await showRevericDialog<void>(
      context: context,
      builder: (dialogCtx) => _SkAlertDialog(
        title: dialogCtx.t(LocaleKeys.agentSkillRevokedTitle),
        sub: item.name,
        icon: RevericIcons.warning_circle,
        note:
            item.executionBlockedReason ??
            dialogCtx.t(LocaleKeys.agentSkillRevokedNote),
        secondaryNote: dialogCtx.t(LocaleKeys.agentSkillRevokedNote),
        actions: [
          RevericButton.primary(
            label: dialogCtx.t(LocaleKeys.agentSkillGotIt),
            onPressed: () => Navigator.of(dialogCtx).maybePop(),
          ),
        ],
      ),
    );
  }
}

enum _RowAction { remove, revoked }

sealed class _SkDialog {
  const _SkDialog();
  const factory _SkDialog.revoked({required NovelAgentSkillModel item}) =
      _SkRevokedDialog;
}

class _SkRevokedDialog implements _SkDialog {
  final NovelAgentSkillModel item;
  const _SkRevokedDialog({required this.item});
}

// ── 已安装列表 ──────────────────────────────────────────────────────────────

class _InstalledList extends StatelessWidget {
  const _InstalledList({
    required this.items,
    required this.onToggle,
    required this.onAction,
    this.onCreate,
    this.onOpen,
    this.onOpenDetail,
  });

  final List<NovelAgentSkillModel> items;
  final ValueChanged<String> onToggle;
  final void Function(_RowAction, NovelAgentSkillModel) onAction;
  final VoidCallback? onCreate;
  final ValueChanged<NovelAgentSkillModel>? onOpen;
  final ValueChanged<NovelAgentSkillModel>? onOpenDetail;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return _EmptyState(
        icon: RevericIcons.layers_outlined,
        title: context.t(LocaleKeys.agentSkillInstalledEmptyTitle),
        text: context.t(LocaleKeys.agentSkillInstalledEmptyText),
        actionLabel: context.t(LocaleKeys.commonCreate),
        onAction: onCreate,
      );
    }
    return ListView(
      padding: const EdgeInsetsDirectional.fromSTEB(
        RevericSpacing.x5l,
        RevericSpacing.x3l,
        RevericSpacing.x5l,
        RevericSpacing.x5l,
      ),
      children: [
        for (final item in items) ...[
          _InstalledRow(
            item: item,
            onToggle: () => onToggle(item.id),
            onAction: (action) => onAction(action, item),
            onOpen: onOpen == null ? null : () => onOpen!(item),
            onOpenDetail: onOpenDetail == null
                ? null
                : () => onOpenDetail!(item),
          ),
          const SizedBox(height: RevericSpacing.lg),
        ],
      ],
    );
  }
}

class _InstalledRow extends StatelessWidget {
  const _InstalledRow({
    required this.item,
    required this.onToggle,
    required this.onAction,
    this.onOpen,
    this.onOpenDetail,
  });

  final NovelAgentSkillModel item;
  final VoidCallback onToggle;
  final ValueChanged<_RowAction> onAction;
  final VoidCallback? onOpen;
  final VoidCallback? onOpenDetail;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final blocked = item.executionBlockedReason != null;
    final isLocal = item.sourceKind == AgentSkillSourceKind.novelLocal;
    return Container(
      padding: const EdgeInsets.all(RevericSpacing.x2l),
      decoration: BoxDecoration(
        color: blocked ? colors.warningBg : colors.surface,
        border: Border.all(
          color: blocked ? colors.warningText : colors.borderInput,
        ),
        borderRadius: BorderRadius.circular(RevericRadius.large),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: InkWell(
              onTap: isLocal ? onOpen : onOpenDetail,
              borderRadius: BorderRadius.circular(RevericRadius.large),
              child: Padding(
                padding: const EdgeInsets.only(right: RevericSpacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: RevericSpacing.sm,
                      runSpacing: RevericSpacing.xxs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          item.name,
                          style: typo.uiSmallSemibold.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                        _SourceBadge(kind: item.sourceKind),
                        if (item.sourceVersion != null)
                          _SkTag(
                            icon: RevericIcons.git_fork,
                            label: 'v${item.sourceVersion}',
                            colors: colors,
                            typo: typo,
                          ),
                      ],
                    ),
                    const SizedBox(height: RevericSpacing.sm),
                    Text(
                      item.description,
                      style: typo.uiSmall.copyWith(color: colors.textMuted),
                    ),
                    if (blocked)
                      Padding(
                        padding: const EdgeInsets.only(top: RevericSpacing.md),
                        child: _InlineChip(
                          icon: RevericIcons.warning_circle,
                          label: context.t(LocaleKeys.agentSkillBlocked),
                          fg: colors.warningText,
                          bg: colors.warningBg,
                          onTap: () => onAction(_RowAction.revoked),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: RevericSpacing.lg),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              RevericMoreMenuButton(
                entries: () => [
                  RevericMenuItem(
                    icon: RevericIcons.delete,
                    iconColor: colors.warningText,
                    labelColor: colors.warningText,
                    label: context.t(LocaleKeys.agentSkillRemove),
                    onTap: () => onAction(_RowAction.remove),
                  ),
                ],
              ),
              const SizedBox(width: RevericSpacing.md),
              RevericSwitch(value: item.enabled, onChanged: (_) => onToggle()),
            ],
          ),
        ],
      ),
    );
  }
}

// ── 占位/空状态 ──────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.text,
    this.actionLabel,
    this.onAction,
  });

  final String icon;
  final String title;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: RevericSpacing.x6l,
          horizontal: RevericSpacing.x4l,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RevericIcon(icon, size: 30, color: colors.textSubtle),
            const SizedBox(height: RevericSpacing.md),
            Text(
              title,
              style: typo.heading2.copyWith(color: colors.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: RevericSpacing.sm),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: typo.ui.copyWith(color: colors.textMuted, height: 1.6),
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: RevericSpacing.lg),
              FilledButton.icon(
                onPressed: onAction,
                icon: RevericIcon(RevericIcons.add, size: 14),
                label: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── 原子组件 ─────────────────────────────────────────────────────────────────

class _SkTag extends StatelessWidget {
  const _SkTag({
    this.icon,
    required this.label,
    required this.colors,
    required this.typo,
  });

  final String? icon;
  final String label;
  final RevericColors colors;
  final RevericTypography typo;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RevericSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceDim,
        borderRadius: BorderRadius.circular(RevericRadius.small),
        border: Border.all(color: colors.borderInput),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            RevericIcon(icon!, size: 12, color: colors.textMuted),
            const SizedBox(width: 4),
          ],
          Text(label, style: typo.uiTiny.copyWith(color: colors.textSecondary)),
        ],
      ),
    );
  }
}

class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.kind});

  final AgentSkillSourceKind kind;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final (icon, label) = switch (kind) {
      AgentSkillSourceKind.novelLocal => (
        RevericIcons.edit_note_outlined,
        context.t(LocaleKeys.agentSkillSourceNovelLocal),
      ),
      AgentSkillSourceKind.official => (
        RevericIcons.seal_check,
        context.t(LocaleKeys.agentSkillSourceOfficial),
      ),
      AgentSkillSourceKind.marketplace => (
        RevericIcons.storefront,
        context.t(LocaleKeys.agentSkillSourceMarketplace),
      ),
    };
    return _SkTag(icon: icon, label: label, colors: colors, typo: typo);
  }
}

class _InlineChip extends StatelessWidget {
  const _InlineChip({
    required this.icon,
    required this.label,
    required this.fg,
    required this.bg,
    this.onTap,
  });

  final String icon;
  final String label;
  final Color fg;
  final Color bg;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final typo = RevericTheme.typographyOf(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(RevericRadius.medium),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.sm,
          vertical: 3,
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(RevericRadius.medium),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            RevericIcon(icon, size: 13, color: fg),
            const SizedBox(width: RevericSpacing.xxs),
            Text(label, style: typo.uiTiny.copyWith(color: fg)),
          ],
        ),
      ),
    );
  }
}

// ── helpers ──────────────────────────────────────────────────────────────────

Future<Directory> _temporaryZipDir() async {
  return getTemporaryDirectory();
}

// ── 对话框外壳与原子 ──────────────────────────────────────────────────────────

class _SkAlertDialog extends StatelessWidget {
  const _SkAlertDialog({
    required this.title,
    required this.icon,
    this.sub,
    this.note,
    this.secondaryNote,
    required this.actions,
  });

  final String title;
  final String icon;
  final String? sub;
  final String? note;
  final String? secondaryNote;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return RevericDialog(
      title: title,
      leading: RevericIcon(icon, color: colors.warningText),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (sub != null) ...[
            Text(sub!),
            const SizedBox(height: RevericSpacing.lg),
          ],
          if (note != null) Text(note!),
          if (secondaryNote != null) ...[
            const SizedBox(height: RevericSpacing.lg),
            Text(secondaryNote!),
          ],
        ],
      ),
      actions: actions,
    );
  }
}
