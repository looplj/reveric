// 职责: 移动端作品编辑页 — 顶部分区切换（概览 + 章节列表 + 角色/大纲/伏笔独立面板 + 世界观/素材目录与图鉴分组列表 + 地图 + 实体关系图 + 当前进展），各分区新建/导入入口统一收口，点击/新建均 push 对应全屏编辑页。
// 关联文件:
//   lib/shared/components/reveric_dialog.dart
//   lib/shared/components/reveric_button.dart
//   lib/shared/widgets/novel_open_boundary.dart
//   lib/mobile/widgets/chapters_panel.dart
//   lib/mobile/widgets/overview_panel.dart
//   lib/mobile/widgets/section_panel.dart
//   lib/mobile/widgets/compendium_panel.dart
//   lib/mobile/services/document_import_orchestrator.dart
//   lib/mobile/widgets/characters_panel.dart
//   lib/mobile/widgets/foreshadowings_panel.dart
//   lib/mobile/widgets/maps_panel.dart
//   lib/mobile/widgets/outlines_panel.dart
//   lib/mobile/widgets/entity_graph_panel.dart
//   lib/shared/widgets/story_progress_panel.dart
//   lib/mobile/pages/novel_agent_rule_manage_page.dart
//   lib/mobile/pages/novel_chat_page.dart
//   lib/shared/services/ai/chat_session_controller.dart
//   lib/shared/widgets/relation_edit_dialog.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/providers/anonymous_reporting_providers.dart
//   lib/shared/providers/maps_providers.dart
//   lib/shared/services/novel_content.dart
//   lib/shared/services/novel_actions.dart
//   lib/shared/database/novel_content_database.dart
//   lib/shared/models/novel.dart
//   lib/shared/theme/theme.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/mobile.json
//   assets/translations/zh-CN/mobile.json
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/editor.json
//   assets/translations/zh-CN/editor.json
//   assets/translations/en/agent_rule.json
//   assets/translations/zh-CN/agent_rule.json
//   assets/translations/en/entity_graph.json
//   assets/translations/zh-CN/entity_graph.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/i18n.md
//   .agents/rules/file-access.md
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../shared/widgets/novel_open_boundary.dart';
import '../../shared/database/novel_content_database.dart';
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/models/novel.dart';
import '../../shared/providers/maps_providers.dart'
    show locationsServiceProvider;
import '../../shared/providers/novel_providers.dart';
import '../../shared/services/ai/chat_session_controller.dart'
    show PendingChatHandoff;
import '../../shared/services/novel_actions.dart';
import '../../shared/theme/theme.dart';
import '../../shared/utils/text_file_decoder.dart';
import '../../shared/widgets/relation_edit_dialog.dart';
import '../../shared/widgets/story_progress_panel.dart';
import '../features/cover_studio/apply_cover.dart';
import '../features/cover_studio/studio_page.dart';
import '../services/document_import_orchestrator.dart';
import '../widgets/characters_panel.dart';
import '../widgets/compendium_panel.dart';
import '../widgets/chapters_panel.dart';
import '../widgets/delete_confirm.dart';
import '../widgets/entity_graph_panel.dart';
import '../widgets/foreshadowings_panel.dart';
import '../widgets/maps_panel.dart';
import '../widgets/outlines_panel.dart';
import '../widgets/overview_panel.dart';
import '../widgets/section_panel.dart';
import 'chapter_editor_page.dart';
import 'character_editor_page.dart';
import 'entry_editor_page.dart';
import 'foreshadowing_editor_page.dart';
import 'location_editor_page.dart';
import 'novel_agent_rule_manage_page.dart';
import 'novel_chat_page.dart';
import 'novel_create_page.dart';
import 'outline_editor_page.dart';
import '../../shared/components/reveric_dialog.dart';
import '../../shared/components/reveric_button.dart';

export '../services/document_import_orchestrator.dart'
    show mobileTextDocumentImportTypeGroup;

/// 分区索引（与 [_sectionLabelKeys] 顺序一致）。用具名常量替代散落的魔法数字，
/// 避免插入「概览」后各处 switch/判断漂移。
const int _sectionOverview = 0;
const int _sectionChapters = 1;
const int _sectionCharacters = 2;
const int _sectionWorldbuilding = 3;
const int _sectionOutlines = 4;
const int _sectionForeshadowings = 5;
const int _sectionCompendium = 6;
const int _sectionMaps = 7;
const int _sectionMaterials = 8;
const int _sectionEntityGraph = 9;
const int _sectionStoryProgress = 10;

/// 编辑器分区。概览置顶并作为进入作品的默认落地分区，其后为写作分区与实体关系图 / 当前进展。
/// Tab labels for the mobile novel detail page; exposed for the tab regression guard.
@visibleForTesting
const List<String> mobileNovelEditorSectionLabelKeys = [
  LocaleKeys.workspaceOverview,
  LocaleKeys.workspaceChapters,
  LocaleKeys.workspaceCharacters,
  LocaleKeys.workspaceLore,
  LocaleKeys.workspaceOutlines,
  LocaleKeys.workspaceForeshadowings,
  LocaleKeys.workspaceSidebarCompendium,
  LocaleKeys.workspaceMaps,
  LocaleKeys.workspaceMaterials,
  LocaleKeys.workspaceEntityGraph,
  LocaleKeys.workspaceStoryProgress,
];

const List<String> _sectionLabelKeys = mobileNovelEditorSectionLabelKeys;

/// 章节分区标题栏新建菜单的可选项：新建章节 / 新建卷。
enum _ChapterCreateKind { chapter, volume }

String _textFileTitle(String fileName) {
  final dotIndex = fileName.lastIndexOf('.');
  return (dotIndex > 0 ? fileName.substring(0, dotIndex) : fileName).trim();
}

/// 简单分区（标题 + markdown 正文同一套表单）。返回 null 表示走独立面板/概览/章节。
MobileEditorSection? _supportedSectionForIndex(int index) => switch (index) {
  _sectionWorldbuilding => MobileEditorSection.lore,
  _sectionMaterials => MobileEditorSection.materials,
  _ => null,
};

/// 概览页跳转目标 → 分区索引。
int _indexForOverviewTarget(MobileOverviewTarget target) => switch (target) {
  MobileOverviewTarget.chapters => _sectionChapters,
  MobileOverviewTarget.lore => _sectionWorldbuilding,
  MobileOverviewTarget.outlines => _sectionOutlines,
  MobileOverviewTarget.characters => _sectionCharacters,
  MobileOverviewTarget.foreshadowings => _sectionForeshadowings,
};

class MobileNovelEditorPage extends HookConsumerWidget {
  const MobileNovelEditorPage({
    super.key,
    required this.novel,
    this.initialChatKickoffPrompt,
    this.openChatOnEntry = false,
  });

  final Novel novel;
  final String? initialChatKickoffPrompt;

  /// 新建小说进入时打开全屏聊天，等待用户输入，不自动发送消息。
  final bool openChatOnEntry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return NovelOpenBoundary(
      novelId: novel.id,
      child: HookConsumer(
        builder: (context, ref, _) => _buildContent(context, ref),
      ),
    );
  }

  Widget _buildContent(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    // 内容库路径：已有则直接复用，否则异步 ensure（建库 + 默认工作区）。
    final databasePath = useState<String?>(
      (novel.contentDatabasePath?.isNotEmpty ?? false)
          ? novel.contentDatabasePath
          : null,
    );
    useEffect(() {
      if (databasePath.value != null) {
        return null;
      }
      Future<void>(() async {
        final path = await ref
            .read(novelActionsProvider)
            .ensureNovelContentDatabasePath(novel);
        if (context.mounted) {
          databasePath.value = path;
        }
      });
      return null;
    }, const []);

    final path = databasePath.value;
    final kickoffPrompt = initialChatKickoffPrompt?.trim();
    final hasKickoff = kickoffPrompt != null && kickoffPrompt.isNotEmpty;
    final kickoffLabel = context.t(LocaleKeys.libraryQuickStart);
    useEffect(() {
      if (path == null || (!openChatOnEntry && !hasKickoff)) {
        return null;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) {
          return;
        }
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => MobileNovelChatPage(
              novelId: novel.id,
              databasePath: path,
              handoff: hasKickoff
                  ? PendingChatHandoff(
                      label: kickoffLabel,
                      content: kickoffPrompt,
                      initialText: kickoffPrompt,
                      autoSend: true,
                    )
                  : null,
            ),
          ),
        );
      });
      return null;
    }, [path, kickoffPrompt, openChatOnEntry]);

    if (path == null) {
      return Scaffold(
        backgroundColor: colors.canvas,
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return _EditorBody(novel: novel, databasePath: path);
  }
}

/// databasePath 确定后才挂载，避免在 null path 下创建 Drift 订阅。
class _EditorBody extends HookConsumerWidget {
  const _EditorBody({required this.novel, required this.databasePath});

  final Novel novel;
  final String databasePath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);

    final service = ref.watch(novelContentServiceProvider(databasePath));
    final chapters =
        ref.watch(chaptersProvider(databasePath)).value ?? const <Chapter>[];

    // 顶部分区切换索引（0 = 概览）；对应 _sectionLabelKeys。
    final selectedSection = useState<int>(_sectionOverview);
    final pageController = usePageController(initialPage: _sectionOverview);
    final documentCreateHandlers = useRef(
      <MobileEditorSection, Future<void> Function()>{},
    );

    void selectSection(int index) {
      if (index == selectedSection.value) {
        return;
      }
      selectedSection.value = index;
      pageController.animateToPage(
        index,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeInOutCubic,
      );
    }

    // 人物详情页里的「在关系图中查看」：弹回本页（本页之上可能叠有角色编辑页等
    // 路由，本页未必是栈底首个路由），再切到关系图分区。
    void openEntityGraphSection() {
      final selfRoute = ModalRoute.of(context);
      if (selfRoute != null) {
        Navigator.of(context).popUntil((route) => route == selfRoute);
      }
      selectSection(_sectionEntityGraph);
    }

    // 各分区新建入口统一收到标题栏右上角；create + 进入编辑页在 page 层完成，
    // 各列表 panel 仅负责列表渲染与条目点击/删除。
    final locationsService = ref.watch(locationsServiceProvider(databasePath));

    // 章节编辑页推入（点击列表项 / 概览继续写作 / 新建章节共用）。
    Future<void> openChapter(String chapterId) {
      return Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MobileChapterEditorPage(
            novel: novel,
            databasePath: databasePath,
            initialChapterId: chapterId,
          ),
        ),
      );
    }

    Future<void> createChapter() async {
      final order = await service.getNextSiblingOrderAtRoot();
      final id = await service.createChapter(siblingOrder: order, title: '');
      if (!context.mounted) {
        return;
      }
      await openChapter(id);
    }

    Future<void> createVolume() async {
      final colors = RevericTheme.colorsOf(context);
      final typo = RevericTheme.typographyOf(context);
      final controller = TextEditingController();

      final title = await showRevericDialog<String>(
        context: context,
        builder: (dialogContext) {
          return RevericDialog(
            title: context.t(LocaleKeys.workspaceNewVolume),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: context.t(LocaleKeys.workspaceNewVolumeHint),
                hintStyle: typo.ui.copyWith(color: colors.textMuted),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(RevericRadius.small),
                  borderSide: BorderSide(color: colors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(RevericRadius.small),
                  borderSide: BorderSide(color: colors.accent),
                ),
              ),
              style: typo.ui.copyWith(color: colors.textPrimary),
            ),
            actions: [
              RevericButton.secondary(
                label: context.t(LocaleKeys.commonCancel),
                onPressed: () => Navigator.of(dialogContext).pop(null),
              ),
              RevericButton.primary(
                label: context.t(LocaleKeys.commonCreate),
                onPressed: () {
                  Navigator.of(dialogContext).pop(controller.text.trim());
                },
              ),
            ],
          );
        },
      );

      if (title == null || title.isEmpty) {
        return;
      }
      // 列表由 chapterTreeProvider stream 自动刷新，无需手动 invalidate。
      await service.createVolume(title: title);
    }

    Future<void> createChapterInVolume(String volumeId) async {
      final order = await service.getNextSiblingOrderInVolume(volumeId);
      final id = await service.createChapter(
        siblingOrder: order,
        parentId: volumeId,
        title: '',
      );
      if (!context.mounted) {
        return;
      }
      await openChapter(id);
    }

    Future<void> renameVolume(String volumeId) async {
      final existing = await service.getChapterById(volumeId);
      if (existing == null || !context.mounted) {
        return;
      }
      final colors = RevericTheme.colorsOf(context);
      final typo = RevericTheme.typographyOf(context);
      final controller = TextEditingController(text: existing.displayTitle);

      final title = await showRevericDialog<String>(
        context: context,
        builder: (dialogContext) {
          return RevericDialog(
            title: context.t(LocaleKeys.workspaceRenameVolume),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: context.t(LocaleKeys.workspaceNewVolumeHint),
                hintStyle: typo.ui.copyWith(color: colors.textMuted),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(RevericRadius.small),
                  borderSide: BorderSide(color: colors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(RevericRadius.small),
                  borderSide: BorderSide(color: colors.accent),
                ),
              ),
              style: typo.ui.copyWith(color: colors.textPrimary),
            ),
            actions: [
              RevericButton.secondary(
                label: context.t(LocaleKeys.commonCancel),
                onPressed: () => Navigator.of(dialogContext).pop(null),
              ),
              RevericButton.primary(
                label: context.t(LocaleKeys.workspaceRenameVolume),
                onPressed: () {
                  Navigator.of(dialogContext).pop(controller.text.trim());
                },
              ),
            ],
          );
        },
      );

      if (title == null || title.isEmpty) {
        return;
      }
      await service.renameVolume(volumeId, title);
    }

    Future<void> deleteVolume(String volumeId) async {
      final existing = await service.getChapterById(volumeId);
      if (existing == null || !context.mounted) {
        return;
      }
      final confirmed = await showMobileDeleteConfirm(
        context,
        title: existing.displayTitle,
      );
      if (!confirmed) {
        return;
      }
      await service.deleteChapter(volumeId);
    }

    Future<void> showCreateChapterOrVolumeSheet() async {
      final colors = RevericTheme.colorsOf(context);
      final source = await showModalBottomSheet<_ChapterCreateKind>(
        context: context,
        backgroundColor: colors.surface,
        isScrollControlled: true,
        showDragHandle: true,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(RevericRadius.x2l),
          ),
        ),
        builder: (sheetContext) {
          final sheetColors = RevericTheme.colorsOf(sheetContext);
          final typo = RevericTheme.typographyOf(sheetContext);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(bottom: RevericSpacing.x5l),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      RevericSpacing.x2l,
                      0,
                      RevericSpacing.x2l,
                      RevericSpacing.sm,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        context.t(LocaleKeys.workspaceAddChapterOrVolume),
                        style: typo.uiSemibold.copyWith(
                          color: sheetColors.textPrimary,
                        ),
                      ),
                    ),
                  ),
                  ListTile(
                    leading: RevericIcon(
                      RevericIcons.description_outlined,
                      size: 20,
                      color: sheetColors.accent,
                    ),
                    title: Text(
                      context.t(LocaleKeys.workspaceNewChapter),
                      style: typo.ui.copyWith(color: sheetColors.textPrimary),
                    ),
                    onTap: () => Navigator.of(
                      sheetContext,
                    ).pop(_ChapterCreateKind.chapter),
                  ),
                  ListTile(
                    leading: RevericIcon(
                      RevericIcons.auto_stories_outlined,
                      size: 20,
                      color: sheetColors.accent,
                    ),
                    title: Text(
                      context.t(LocaleKeys.workspaceNewVolume),
                      style: typo.ui.copyWith(color: sheetColors.textPrimary),
                    ),
                    onTap: () => Navigator.of(
                      sheetContext,
                    ).pop(_ChapterCreateKind.volume),
                  ),
                ],
              ),
            ),
          );
        },
      );
      if (!context.mounted || source == null) {
        return;
      }
      switch (source) {
        case _ChapterCreateKind.chapter:
          await createChapter();
        case _ChapterCreateKind.volume:
          await createVolume();
      }
    }

    Future<void> createOutline() async {
      final id = await service.outlineService.createOutline(
        defaultTitle: context.t(LocaleKeys.workspaceNewOutline),
      );
      if (!context.mounted) {
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MobileOutlineEditorPage(
            databasePath: databasePath,
            outlineId: id,
          ),
        ),
      );
    }

    Future<void> createCharacter() async {
      final id = await service.createCharacterProfile(
        defaultName: context.t(LocaleKeys.workspaceNewCharacter),
      );
      if (!context.mounted) {
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MobileCharacterEditorPage(
            databasePath: databasePath,
            characterId: id,
          ),
        ),
      );
    }

    Future<void> createForeshadowing() async {
      final id = await service.createForeshadowing(
        defaultTitle: context.t(LocaleKeys.workspaceNewForeshadowing),
      );
      if (!context.mounted) {
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MobileForeshadowingEditorPage(
            novelId: novel.id,
            databasePath: databasePath,
            foreshadowingId: id,
          ),
        ),
      );
    }

    Future<void> createWorld() async {
      final id = await locationsService.createLocationWithDefaultName(
        defaultName: context.t(LocaleKeys.mobileEditorNewWorld),
        type: locationTypeWorld,
        parentId: null,
      );
      if (!context.mounted) {
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MobileLocationEditorPage(
            databasePath: databasePath,
            locationId: id,
          ),
        ),
      );
    }

    Future<void> createSimpleEntry(MobileEditorSection section) async {
      final defaultTitle = context.t(section.newLabelKey);
      final String id;
      if (section.isDocument) {
        id = await service.documentsService.createDocument(
          type: section.typeValue,
          defaultTitle: defaultTitle,
        );
      } else {
        id = await service.createItem(
          type: section.typeValue,
          defaultTitle: defaultTitle,
        );
      }
      if (!context.mounted) {
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MobileEntryEditorPage(
            databasePath: databasePath,
            section: section,
            entryId: id,
          ),
        ),
      );
    }

    Future<void> importOutline() async {
      final files = await openFiles(
        acceptedTypeGroups: const [mobileTextDocumentImportTypeGroup],
      );
      if (!context.mounted || files.isEmpty) {
        return;
      }

      showRevericDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );

      String? firstOutlineId;
      var importSucceeded = false;
      try {
        final fallbackTitle = context.t(LocaleKeys.workspaceNewOutline);
        for (final file in files) {
          final title = _textFileTitle(file.name);
          final outlineTitle = title.isEmpty ? fallbackTitle : title;
          final outlineId = await service.outlineService.importOutline(
            title: outlineTitle,
            content: decodeImportedTextBytes(await file.readAsBytes()),
          );
          firstOutlineId ??= outlineId;
        }
        importSucceeded = true;
        if (!context.mounted) {
          return;
        }
        ref.invalidate(outlinesProvider(databasePath));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.t(
                LocaleKeys.workspaceImportResult,
                namedArgs: {'count': '${files.length}'},
              ),
            ),
          ),
        );
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(context.t(LocaleKeys.workspaceImportFailed)),
            ),
          );
        }
      } finally {
        if (context.mounted) {
          Navigator.of(context, rootNavigator: true).pop();
        }
      }

      // 全部导入成功后打开第一个大纲，其余按顺序保留在列表中。
      final targetOutlineId = firstOutlineId;
      if (importSucceeded && targetOutlineId != null && context.mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => MobileOutlineEditorPage(
              databasePath: databasePath,
              outlineId: targetOutlineId,
            ),
          ),
        );
      }
    }

    void createSimpleOrDocument(MobileEditorSection section) {
      if (section.isDocument) {
        final create = documentCreateHandlers.value[section];
        if (create != null) {
          create();
          return;
        }
      }
      createSimpleEntry(section);
    }

    // 当前分区的新建入口与文案；概览无新建入口。
    final VoidCallback? onCreate;
    final String? createLabel;
    switch (selectedSection.value) {
      case _sectionChapters:
        onCreate = showCreateChapterOrVolumeSheet;
        createLabel = context.t(LocaleKeys.workspaceNewChapter);
      case _sectionCharacters:
        onCreate = createCharacter;
        createLabel = context.t(LocaleKeys.workspaceNewCharacter);
      case _sectionOutlines:
        onCreate = createOutline;
        createLabel = context.t(LocaleKeys.workspaceNewOutline);
      case _sectionForeshadowings:
        onCreate = createForeshadowing;
        createLabel = context.t(LocaleKeys.workspaceNewForeshadowing);
      case _sectionCompendium:
        onCreate = () async {
          final section = await showMobileCompendiumCreateSheet(context);
          if (section != null && context.mounted) {
            await createSimpleEntry(section);
          }
        };
        createLabel = context.t(LocaleKeys.workspaceNewCompendiumEntry);
      case _sectionMaps:
        onCreate = createWorld;
        createLabel = context.t(LocaleKeys.mapEditorCreateWorldTitle);
      case _sectionEntityGraph:
        // 关系图无独立条目；新建入口直接打开关系编辑对话框（复用共享 dialog）。
        onCreate = () =>
            RelationEditDialog.show(context, databasePath: databasePath);
        createLabel = context.t(LocaleKeys.entityGraphAddRelation);
      default:
        final simple = _supportedSectionForIndex(selectedSection.value);
        if (simple != null) {
          onCreate = () => createSimpleOrDocument(simple);
          createLabel = context.t(simple.newLabelKey);
        } else {
          onCreate = null;
          createLabel = null;
        }
    }

    VoidCallback onCreateFor(int index) {
      return switch (index) {
        _sectionChapters => createChapter,
        _sectionCharacters => createCharacter,
        _sectionOutlines => createOutline,
        _sectionForeshadowings => createForeshadowing,
        _sectionMaps => createWorld,
        _sectionEntityGraph => () => RelationEditDialog.show(
          context,
          databasePath: databasePath,
        ),
        _ => () {
          final simple = _supportedSectionForIndex(index);
          if (simple != null) {
            createSimpleOrDocument(simple);
          }
        },
      };
    }

    Future<void> uploadCover() async {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (!context.mounted || picked == null) {
        return;
      }
      await applyMobileNovelCover(
        context,
        ref,
        novel: novel,
        localFilePath: picked.path,
        successKey: LocaleKeys.commonSaved,
      );
    }

    Widget sectionBodyFor(int index) {
      final sectionOnCreate = onCreateFor(index);
      final simpleSection = _supportedSectionForIndex(index);
      if (simpleSection != null) {
        return MobileSectionPanel(
          databasePath: databasePath,
          section: simpleSection,
          onCreate: sectionOnCreate,
          onRegisterDocumentCreate: simpleSection.isDocument
              ? (create) {
                  if (create == null) {
                    documentCreateHandlers.value.remove(simpleSection);
                  } else {
                    documentCreateHandlers.value[simpleSection] = create;
                  }
                }
              : null,
        );
      }
      return switch (index) {
        _sectionCompendium => MobileCompendiumPanel(
          databasePath: databasePath,
          onCreate: createSimpleEntry,
        ),
        _sectionOverview => MobileOverviewPanel(
          novel: novel,
          databasePath: databasePath,
          onOpenSection: (target) =>
              selectSection(_indexForOverviewTarget(target)),
          onContinueWriting: (prompt) => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => MobileNovelChatPage(
                novelId: novel.id,
                databasePath: databasePath,
                handoff: PendingChatHandoff(
                  label: prompt,
                  content: prompt,
                  initialText: prompt,
                  autoSend: true,
                ),
              ),
            ),
          ),
          onOpenChat: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => MobileNovelChatPage(
                novelId: novel.id,
                databasePath: databasePath,
              ),
            ),
          ),
          onOpenChatWithPrompt: (prompt) => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => MobileNovelChatPage(
                novelId: novel.id,
                databasePath: databasePath,
                handoff: PendingChatHandoff(
                  label: prompt,
                  content: prompt,
                  initialText: prompt,
                ),
              ),
            ),
          ),
          onEditNovel: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => MobileNovelCreatePage(existingNovel: novel),
            ),
          ),
          onOpenAgentRules: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => MobileNovelAgentRuleManagePage(
                novel: novel,
                databasePath: databasePath,
              ),
            ),
          ),
          onOpenCoverStudio: (currentNovel) => openMobileCoverStudioPage(
            context,
            novel: currentNovel,
            databasePath: databasePath,
            onApply: (assetId) => applyMobileNovelCover(
              context,
              ref,
              novel: currentNovel,
              assetId: assetId,
            ),
          ),
          onUploadCover: uploadCover,
        ),
        _sectionChapters => MobileChaptersPanel(
          novel: novel,
          databasePath: databasePath,
          onOpenChapter: openChapter,
          onCreate: sectionOnCreate,
          onCreateVolume: createVolume,
          onCreateChapterInVolume: createChapterInVolume,
          onRenameVolume: renameVolume,
          onDeleteVolume: deleteVolume,
        ),
        _sectionCharacters => MobileCharactersPanel(
          databasePath: databasePath,
          onCreate: sectionOnCreate,
          onOpenGraph: openEntityGraphSection,
        ),
        _sectionOutlines => MobileOutlinesPanel(
          databasePath: databasePath,
          onCreate: sectionOnCreate,
          onImport: importOutline,
        ),
        _sectionForeshadowings => MobileForeshadowingsPanel(
          novelId: novel.id,
          databasePath: databasePath,
          onCreate: sectionOnCreate,
        ),
        _sectionMaps => MobileMapsPanel(
          novelId: novel.id,
          databasePath: databasePath,
          onCreate: sectionOnCreate,
        ),
        _sectionEntityGraph => MobileEntityGraphPanel(
          novelId: novel.id,
          databasePath: databasePath,
          onCreate: sectionOnCreate,
        ),
        _sectionStoryProgress => StoryProgressPanel(
          databasePath: databasePath,
          chapters: chapters,
          padding: const EdgeInsets.fromLTRB(
            RevericSpacing.x2l,
            RevericSpacing.x2l,
            RevericSpacing.x2l,
            RevericSpacing.x4l,
          ),
        ),
        _ => throw StateError('Unhandled mobile editor section: $index'),
      };
    }

    return Scaffold(
      backgroundColor: colors.canvas,
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            Column(
              children: [
                _EditorHeader(
                  novel: novel,
                  selectedSection: selectedSection.value,
                  sectionLabel: context.t(
                    _sectionLabelKeys[selectedSection.value],
                  ),
                  createLabel: createLabel,
                  onCreate: onCreate,
                  onSelectSection: selectSection,
                ),
                // 快速开书草稿：头部下方提示条，「加入书架」后作品才进书库。
                if (novel.draft)
                  _AddToLibraryBanner(
                    onAdd: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      try {
                        await ref
                            .read(novelActionsProvider)
                            .clearNovelDraft(novel.id);
                      } on NovelTitleConflictException catch (error) {
                        if (!context.mounted) {
                          return;
                        }
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(
                              context.t(
                                LocaleKeys.libraryDuplicateName,
                                namedArgs: {'name': error.title},
                              ),
                            ),
                          ),
                        );
                        return;
                      }
                      if (!context.mounted) {
                        return;
                      }
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text(
                            context.t(LocaleKeys.libraryAddedToLibrary),
                          ),
                        ),
                      );
                    },
                  ),
                Expanded(
                  child: PageView.builder(
                    controller: pageController,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _sectionLabelKeys.length,
                    itemBuilder: (context, index) => sectionBodyFor(index),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 快速开书草稿的提示条（编辑器头部下方）：说明尚未加入书架并提供「加入书架」按钮。
class _AddToLibraryBanner extends StatelessWidget {
  const _AddToLibraryBanner({required this.onAdd});

  final Future<void> Function() onAdd;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Container(
      margin: const EdgeInsets.fromLTRB(
        RevericSpacing.x3l,
        0,
        RevericSpacing.x3l,
        RevericSpacing.sm,
      ),
      padding: const EdgeInsets.only(
        left: RevericSpacing.lg,
        right: RevericSpacing.sm,
        top: RevericSpacing.sm,
        bottom: RevericSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.selected,
        borderRadius: BorderRadius.circular(RevericRadius.large),
      ),
      child: Row(
        children: [
          RevericIcon(
            RevericIcons.auto_awesome,
            size: 18,
            color: colors.accent,
          ),
          const SizedBox(width: RevericSpacing.md),
          Expanded(
            child: Text(
              context.t(LocaleKeys.libraryDraftShelfHint),
              style: typo.uiSmall.copyWith(color: colors.textSecondary),
            ),
          ),
          const SizedBox(width: RevericSpacing.sm),
          Material(
            color: colors.accent,
            borderRadius: BorderRadius.circular(RevericRadius.pill),
            child: InkWell(
              onTap: onAdd,
              borderRadius: BorderRadius.circular(RevericRadius.pill),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: RevericSpacing.lg,
                  vertical: RevericSpacing.xs,
                ),
                child: Text(
                  context.t(LocaleKeys.libraryAddToLibrary),
                  style: typo.uiSmallSemibold.copyWith(color: colors.onAccent),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EditorHeader extends StatelessWidget {
  const _EditorHeader({
    required this.novel,
    required this.selectedSection,
    required this.sectionLabel,
    required this.createLabel,
    required this.onCreate,
    required this.onSelectSection,
  });

  final Novel novel;

  /// 当前分区索引（对应 [_sectionLabelKeys]）。
  final int selectedSection;

  /// 当前分区名（标题副标题）。
  final String sectionLabel;

  /// 新建文案与入口；无新建入口的分区（概览）为 null。
  final String? createLabel;
  final VoidCallback? onCreate;
  final ValueChanged<int> onSelectSection;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            RevericSpacing.xs,
            RevericSpacing.sm,
            RevericSpacing.xs,
            RevericSpacing.sm,
          ),
          child: Row(
            children: [
              _HeaderIconButton(
                icon: RevericIcons.arrow_back,
                onTap: () => Navigator.of(context).maybePop(),
              ),
              Expanded(
                child: Column(
                  children: [
                    Text(
                      novel.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typo.uiSemibold.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    if (sectionLabel.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        sectionLabel,
                        style: typo.uiTiny.copyWith(color: colors.textMuted),
                      ),
                    ],
                  ],
                ),
              ),
              // 新建入口统一放在标题栏右上角（概览无新建入口）。
              if (createLabel != null && onCreate != null)
                _HeaderCreateButton(onTap: onCreate!),
            ],
          ),
        ),
        _SectionChips(
          selectedIndex: selectedSection,
          onSelect: onSelectSection,
        ),
      ],
    );
  }
}

/// 标题栏右上角的新建按钮（无底色，黑/白随主题适配）。
class _HeaderCreateButton extends StatelessWidget {
  const _HeaderCreateButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Padding(
        padding: const EdgeInsets.all(RevericSpacing.sm),
        child: RevericIcon(
          RevericIcons.add,
          size: 22,
          color: colors.textPrimary,
        ),
      ),
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({required this.icon, required this.onTap});

  final String icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Padding(
        padding: const EdgeInsets.all(RevericSpacing.sm),
        child: RevericIcon(icon, size: 22, color: colors.textSecondary),
      ),
    );
  }
}

class _SectionChips extends HookWidget {
  const _SectionChips({required this.selectedIndex, required this.onSelect});

  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final scrollController = useScrollController();
    final chipKeys = useMemoized(
      () => List.generate(_sectionLabelKeys.length, (_) => GlobalKey()),
      const [],
    );

    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final chipContext = chipKeys[selectedIndex].currentContext;
        if (chipContext != null) {
          Scrollable.ensureVisible(
            chipContext,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOutCubic,
            alignment: 0.5,
          );
        }
      });
      return null;
    }, [selectedIndex]);

    return SizedBox(
      height: 42,
      child: ListView.separated(
        controller: scrollController,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(
          RevericSpacing.xl,
          0,
          RevericSpacing.xl,
          RevericSpacing.lg,
        ),
        itemCount: _sectionLabelKeys.length,
        separatorBuilder: (_, _) => const SizedBox(width: RevericSpacing.xs),
        itemBuilder: (context, index) {
          final key = _sectionLabelKeys[index];
          final isActive = index == selectedIndex;
          return InkWell(
            key: chipKeys[index],
            onTap: () => onSelect(index),
            borderRadius: BorderRadius.circular(RevericRadius.pill),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOutCubic,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(
                horizontal: RevericSpacing.xl,
              ),
              decoration: BoxDecoration(
                color: isActive ? colors.accent : colors.surface,
                borderRadius: BorderRadius.circular(RevericRadius.pill),
                border: Border.all(
                  color: isActive ? colors.accent : colors.borderSubtle,
                ),
              ),
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOutCubic,
                style: typo.uiSmallSemibold.copyWith(
                  color: isActive ? colors.onAccent : colors.textSecondary,
                ),
                child: Text(context.t(key)),
              ),
            ),
          );
        },
      ),
    );
  }
}
