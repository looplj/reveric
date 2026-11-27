// 职责: 移动端章节正文编辑页 — 全屏写作（标题/大纲折叠/正文、防抖自动保存、字数、退出冲刷）、正文实体提及卡片、目录切章、角色面板、AI 助手入口。
// 关联文件:
//   lib/shared/components/reveric_dialog.dart
//   lib/shared/components/reveric_button.dart
//   lib/mobile/pages/novel_editor_page.dart
//   lib/mobile/widgets/chapter_toc_sheet.dart
//   lib/mobile/pages/novel_chat_page.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/providers/maps_providers.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/services/novel_content.dart
//   lib/shared/services/chapter_save.dart
//   lib/shared/database/novel_content_database.dart
//   lib/shared/models/novel.dart
//   lib/shared/models/character_profile.dart
//   lib/shared/utils/chapter_entity_recognition.dart
//   lib/shared/utils/chapter_text_formatter.dart
//   lib/shared/utils/text_input_formatters.dart
//   lib/shared/utils/text_input_composing.dart
//   lib/shared/widgets/entity_card.dart
//   lib/shared/widgets/chapter_copy_replace_panel.dart
//   lib/shared/widgets/character_avatar.dart
//   lib/shared/widgets/editor_line_numbers.dart
//   lib/mobile/pages/chapter_history_page.dart
//   lib/mobile/widgets/editor_focus_lines.dart
//   lib/shared/widgets/md/reveric_markdown_editor.dart
//   lib/shared/theme/theme.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/mobile.json
//   assets/translations/zh-CN/mobile.json
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/character.json
//   assets/translations/zh-CN/character.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/chapter.json
//   assets/translations/zh-CN/chapter.json
//   assets/translations/en/history.json
//   assets/translations/zh-CN/history.json
//   lib/shared/components/reveric_context_menu.dart
//   lib/shared/models/novel_workspace.dart
//   lib/shared/services/ai/chat_session_controller.dart
//   lib/shared/services/chapter_format_all.dart
//   lib/shared/widgets/confirm_dialog.dart
//   lib/shared/widgets/format_all_progress_dialog.dart
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/text-input-ime.md
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/i18n.md
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/database/novel_content_database.dart';
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/models/character_profile.dart';
import '../../shared/models/novel.dart';
import '../../shared/providers/maps_providers.dart' show locationsProvider;
import '../../shared/providers/novel_providers.dart';
import '../../shared/providers/settings_providers.dart';
import '../../shared/components/reveric_checkbox.dart';
import '../../shared/components/reveric_context_menu.dart';
import '../../shared/models/novel_workspace.dart';
import '../../shared/services/ai/chat_session_controller.dart';
import '../../shared/services/chapter_format_all.dart';
import '../../shared/services/chapter_save.dart';
import '../../shared/theme/theme.dart';
import '../../shared/utils/chapter_entity_recognition.dart';
import '../../shared/utils/chapter_text_formatter.dart';
import '../../shared/utils/text_input_formatters.dart';
import '../../shared/utils/text_input_composing.dart';
import '../../shared/widgets/chapter/dialogue_highlight_controller.dart';
import '../../shared/widgets/chapter/highlight_selection.dart';
import '../../shared/widgets/chapter_copy_replace_panel.dart';
import '../../shared/widgets/entity_card.dart';
import '../../shared/widgets/confirm_dialog.dart';
import '../../shared/widgets/format_all_progress_dialog.dart';
import '../../shared/widgets/character_avatar.dart';
import '../../shared/widgets/editor_line_numbers.dart';
import '../../shared/widgets/md/reveric_markdown_editor.dart';
import '../widgets/chapter_toc_sheet.dart';
import '../widgets/editor_focus_lines.dart';
import 'chapter_history_page.dart';
import 'chapter_preview_page.dart';
import 'editor_settings_page.dart';
import 'novel_chat_page.dart';
import '../../shared/components/reveric_dialog.dart';
import '../../shared/components/reveric_button.dart';

/// 非空白字符计数，作为编辑中实时「字数」展示（持久化字数由 service 计算）。
int _countChars(String text) =>
    text.replaceAll(RegExp(r'\s+'), '').runes.length;

/// 章节的三个可编辑字段。脏标记与外部写入回灌都按字段独立处理，
/// 这样「用户改标题 + AI 改正文」不会互相覆盖。
enum _ChapterEditField { title, outline, content }

/// 把外部权威文本写回 controller，尽量保留光标位置。
///
/// 切章（[resetCursor]）时光标落到末尾；AI 等外部改写时按原偏移 clamp，
/// 避免用户正在阅读的位置被弹到文末。
void _writeControllerText(
  TextEditingController controller,
  String next, {
  bool resetCursor = false,
}) {
  if (controller.text == next) {
    return;
  }
  final base = controller.selection.baseOffset;
  final offset = resetCursor || base < 0
      ? next.length
      : base.clamp(0, next.length).toInt();
  controller.value = TextEditingValue(
    text: next,
    selection: TextSelection.collapsed(offset: offset),
  );
}

/// 章节编辑会话的非 UI 状态：脏字段追踪、自动保存串行队列，以及用于区分
/// 「本页写入的回声」与「AI 等外部写入」的同步基线。
///
/// 抽成独立对象而不是继续往 page build 里堆 `useRef` —— 见
/// `.agents/rules/widget-decomposition.md` 的可数信号（co-located 状态 > 10）。
class _ChapterEditSession {
  _ChapterEditSession({
    required this.titleController,
    required this.outlineController,
    required this.contentController,
  });

  final TextEditingController titleController;
  final TextEditingController outlineController;
  final TextEditingController contentController;

  String? loadedChapterId;
  Timer? autoSaveTimer;

  /// 保存串行队列：防抖保存、切章冲刷、退出冲刷可能重叠，必须按序落盘，
  /// 否则后发起的写入可能先返回，把旧快照盖在新快照上。
  Future<void> saveQueue = Future<void>.value();

  /// 程序化写 outline controller 期间屏蔽 listener，避免把灌入误判成用户改动。
  bool suppressOutlineListener = false;

  bool dirtyTitle = false;
  bool dirtyOutline = false;
  bool dirtyContent = false;

  /// 已经与本页对账过的 DB 值：本页写进去的，或从 DB 读到并接受过的。
  /// 回流值等于基线即为回声（跳过），不等才是外部改写（按字段回灌）。
  String _syncedTitle = '';
  String _syncedOutline = '';
  String _syncedContent = '';

  bool get dirty => dirtyTitle || dirtyOutline || dirtyContent;

  /// 任一输入框正在 IME 组词（中文拼音等），此时回灌会误触发上屏。
  bool get composing =>
      isTextInputComposing(titleController) ||
      isTextInputComposing(outlineController) ||
      isTextInputComposing(contentController);

  void markEdited(_ChapterEditField field) {
    switch (field) {
      case _ChapterEditField.title:
        dirtyTitle = true;
      case _ChapterEditField.outline:
        dirtyOutline = true;
      case _ChapterEditField.content:
        dirtyContent = true;
    }
  }

  /// 切章：整章灌入 controller，光标归位到末尾，基线重置为该章当前值。
  void loadChapter(Chapter chapter) {
    final title = chapter.title ?? '';
    _writeControllerText(titleController, title, resetCursor: true);
    _writeControllerText(contentController, chapter.content, resetCursor: true);
    suppressOutlineListener = true;
    try {
      _writeControllerText(
        outlineController,
        chapter.outline,
        resetCursor: true,
      );
    } finally {
      suppressOutlineListener = false;
    }
    loadedChapterId = chapter.id;
    dirtyTitle = false;
    dirtyOutline = false;
    dirtyContent = false;
    _syncedTitle = title;
    _syncedOutline = chapter.outline;
    _syncedContent = chapter.content;
  }

  /// 记录一次落盘：基线推进到实际写入 DB 的值。
  ///
  /// 标题按 trim 后比较（落盘前会 trim，controller 里可能还留着尾随空格）；
  /// 正文/大纲原样落盘，直接全等比较。保存期间用户又改过的字段保持脏。
  void markPersisted({
    required String title,
    required String outline,
    required String content,
  }) {
    _syncedTitle = title;
    _syncedOutline = outline;
    _syncedContent = content;
    if (titleController.text.trim() == title) {
      dirtyTitle = false;
    }
    if (outlineController.text == outline) {
      dirtyOutline = false;
    }
    if (contentController.text == content) {
      dirtyContent = false;
    }
  }

  /// 同章回流：只处理相对基线真正变化的字段（即 AI 等外部写入）。
  ///
  /// 基线无条件推进（代表「这份 DB 值已对账」），但只有本地未在编辑该字段时
  /// 才回灌 controller；用户正在改的字段保留本地版本，交由自动保存写回。
  /// 返回实际回灌的字段。
  Set<_ChapterEditField> adoptExternalChanges(Chapter chapter) {
    final adopted = <_ChapterEditField>{};
    final title = chapter.title ?? '';
    if (title != _syncedTitle) {
      _syncedTitle = title;
      if (!dirtyTitle) {
        _writeControllerText(titleController, title);
        adopted.add(_ChapterEditField.title);
      }
    }
    if (chapter.outline != _syncedOutline) {
      _syncedOutline = chapter.outline;
      if (!dirtyOutline) {
        suppressOutlineListener = true;
        try {
          _writeControllerText(outlineController, chapter.outline);
        } finally {
          suppressOutlineListener = false;
        }
        adopted.add(_ChapterEditField.outline);
      }
    }
    if (chapter.content != _syncedContent) {
      _syncedContent = chapter.content;
      if (!dirtyContent) {
        _writeControllerText(contentController, chapter.content);
        adopted.add(_ChapterEditField.content);
      }
    }
    return adopted;
  }
}

/// 章节正文全屏编辑页。以 [MaterialPageRoute] 推入；内部维护 [initialChapterId]
/// 起始的当前章 id，目录 sheet 切章不退栈。
class MobileChapterEditorPage extends HookConsumerWidget {
  const MobileChapterEditorPage({
    super.key,
    required this.novel,
    required this.databasePath,
    required this.initialChapterId,
  });

  final Novel novel;
  final String databasePath;
  final String initialChapterId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final entityRecognitionEnabled = ref.watch(
      editorEntityRecognitionEnabledProvider,
    );

    final service = ref.watch(
      workContentServiceProvider((path: databasePath, novelId: novel.id)),
    );
    final chaptersAsync = ref.watch(chapterTreeProvider(databasePath));

    // 工作区资料（角色/地点/技能/物品/生物/势力），用于正文实体提及目录与角色面板。
    final charactersAsync = ref.watch(characterProfilesProvider(databasePath));
    final locationsAsync = ref.watch(locationsProvider(databasePath));
    final skillsAsync = ref.watch(
      itemsProvider(path: databasePath, type: 'skill'),
    );
    final itemsAsync = ref.watch(
      itemsProvider(path: databasePath, type: 'item'),
    );
    final creaturesAsync = ref.watch(
      itemsProvider(path: databasePath, type: 'creature'),
    );
    final factionsAsync = ref.watch(
      itemsProvider(path: databasePath, type: 'faction'),
    );
    final characters =
        charactersAsync.asData?.value ?? const <CharacterProfile>[];
    final entityCatalog = buildChapterEntityCatalog(
      enabled: entityRecognitionEnabled,
      characters: characters,
      locations: locationsAsync.asData?.value ?? const <Location>[],
      skills: skillsAsync.asData?.value ?? const <Item>[],
      items: itemsAsync.asData?.value ?? const <Item>[],
      creatures: creaturesAsync.asData?.value ?? const <Item>[],
      factions: factionsAsync.asData?.value ?? const <Item>[],
    );

    final selectedChapterId = useState<String>(initialChapterId);

    final activeChapterAsync = ref.watch(
      chapterContentByIdProvider(
        path: databasePath,
        chapterId: selectedChapterId.value,
      ),
    );
    final activeChapter = activeChapterAsync.asData?.value;
    final chapters = chaptersAsync.asData?.value ?? const <Chapter>[];
    // 正文流（watchContentById）不含 VIEW 计算章号，章号从章节树 meta 解析。
    final activeChapterNumber = activeChapter == null
        ? null
        : _resolveActiveChapterNumber(activeChapter, chapters);

    final titleController = useTextEditingController();
    final bodyController = useMemoized(ChapterDialogueHighlightController.new);
    useEffect(() => bodyController.dispose, [bodyController]);
    final outlineController = useTextEditingController();
    final session = useMemoized(
      () => _ChapterEditSession(
        titleController: titleController,
        outlineController: outlineController,
        contentController: bodyController,
      ),
      const [],
    );
    final wordCount = useState<int>(0);
    // (saving, savedAt)
    final saveState = useState<(bool, DateTime?)>((false, null));

    /// 返回是否成功落盘。写入串行化，避免重叠的保存互相盖旧快照。
    Future<bool> persist(
      String id,
      String outline,
      String title,
      String content, {
      bool rethrowOnFailure = false,
    }) {
      final before = activeChapter;
      final overlay = before != null && before.id == id
          ? ref.read(
              workOverlayServiceProvider((
                path: databasePath,
                novelId: novel.id,
              )),
            )
          : null;
      // 落盘的标题以 trim 后为准，历史记录与 chapters 表保持同一份值。
      final storedTitle = title.trim();

      Future<bool> run() async {
        if (context.mounted) {
          saveState.value = (true, saveState.value.$2);
        }
        try {
          // 与桌面 saveChapter 一致：先按字段 stage 变更并提交 manual commit，
          // 再写 chapters 表，保证修改历史可回溯/回滚。
          if (before != null && overlay != null) {
            await commitChapterManualSave(
              overlay,
              service,
              chapterId: id,
              newTitle: storedTitle,
              newOutline: outline,
              newContent: content,
            );
          }
          await service.updateChapterContent(
            chapterId: id,
            title: storedTitle,
            outline: outline,
            content: content,
            preserveHighlightSelection: true,
          );
          if (session.loadedChapterId == id) {
            session.markPersisted(
              title: storedTitle,
              outline: outline,
              content: content,
            );
          }
          if (context.mounted) {
            saveState.value = (false, DateTime.now());
          }
          return true;
        } catch (error, stackTrace) {
          // service 已记录 [DB] 日志；UI 仅回到非保存中状态，不透出底层异常。
          if (context.mounted) {
            saveState.value = (false, saveState.value.$2);
          }
          if (rethrowOnFailure) {
            Error.throwWithStackTrace(error, stackTrace);
          }
          return false;
        }
      }

      final operation = session.saveQueue.then((_) => run());
      session.saveQueue = operation.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
      return operation;
    }

    void scheduleSave(_ChapterEditField field) {
      final id = session.loadedChapterId;
      if (id == null) {
        return;
      }
      session.markEdited(field);
      session.autoSaveTimer?.cancel();
      session.autoSaveTimer = Timer(const Duration(milliseconds: 800), () {
        persist(
          id,
          outlineController.text,
          titleController.text,
          bodyController.text,
        );
      });
    }

    // 大纲编辑器没有 onChanged 回调，借助 controller 监听触发自动保存。
    // 程序化灌入时由 session 屏蔽，避免把载入/回灌误判为用户改动。
    useEffect(() {
      void outlineListener() {
        if (session.suppressOutlineListener) {
          return;
        }
        scheduleSave(_ChapterEditField.outline);
      }

      outlineController.addListener(outlineListener);
      return () => outlineController.removeListener(outlineListener);
    }, const []);

    // 退出页面时若仍有未落盘的改动，立即冲刷一次（直接走 service，不再 setState）。
    // 底层内容库 provider 为 keepAlive，即便本页 service provider 释放也能写入。
    useEffect(
      () => () {
        session.autoSaveTimer?.cancel();
        final id = session.loadedChapterId;
        if (!session.dirty || id == null) {
          return;
        }
        // controller 先于本 effect dispose，文本必须在此同步取出再挂到队列上。
        final title = titleController.text.trim();
        final outline = outlineController.text;
        final content = bodyController.text;
        unawaited(
          session.saveQueue.then(
            (_) => service.updateChapterContent(
              chapterId: id,
              title: title,
              outline: outline,
              content: content,
              preserveHighlightSelection: true,
            ),
          ),
        );
      },
      const [],
    );

    // 切章时整章灌入；同一章节被 AI 等外部写入更新时，按字段回灌「相对基线真正
    // 变化」的部分。本页自己落盘的回流等于基线，会被识别为回声而跳过，不会把
    // 用户正在输入的段末空行冲掉、也不会把光标弹到文末。
    useEffect(() {
      final ch = activeChapter;
      if (ch == null) {
        return null;
      }
      final prevId = session.loadedChapterId;
      if (prevId != ch.id) {
        if (prevId != null && session.dirty) {
          session.autoSaveTimer?.cancel();
          persist(
            prevId,
            outlineController.text,
            titleController.text,
            bodyController.text,
          );
        }
        session.loadChapter(ch);
        wordCount.value = _countChars(ch.content);
        saveState.value = (false, ch.updatedAt);
        return null;
      }
      // IME 组词期间回灌会误触发上屏，等下一次回流再处理。
      if (session.composing) {
        return null;
      }
      final adopted = session.adoptExternalChanges(ch);
      if (adopted.isEmpty) {
        return null;
      }
      if (adopted.contains(_ChapterEditField.content)) {
        wordCount.value = _countChars(bodyController.text);
      }
      saveState.value = (false, ch.updatedAt);
      return null;
    }, [activeChapter]);

    Future<bool> flushPendingEdit() async {
      session.autoSaveTimer?.cancel();
      await session.saveQueue;
      final id = session.loadedChapterId;
      if (!session.dirty || id == null) {
        return true;
      }
      return persist(
        id,
        outlineController.text,
        titleController.text,
        bodyController.text,
      );
    }

    Future<void> openAssistant() async {
      // 先把未落盘的改动冲刷掉，AI 才能读到最新正文；落盘失败必须明确告知，
      // 否则用户点了没反应，且 AI 会基于旧内容改写。
      if (!await flushPendingEdit()) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.t(LocaleKeys.commonSaveFailed))),
          );
        }
        return;
      }
      if (!context.mounted) {
        return;
      }
      // AI 经 working overlay 写 chapters 表后，本页的 chapter 流会回流，
      // 上面的 effect 按字段回灌即可，无需在此另外回读一次。
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MobileNovelChatPage(
            novelId: novel.id,
            databasePath: databasePath,
            chapterId: activeChapter?.id,
            chapterTitle: activeChapter?.title,
            chapterNumber: activeChapterNumber,
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: colors.canvas,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _ChapterEditorHeader(
              novel: novel,
              activeChapter: activeChapter,
              chapterNumber: activeChapterNumber,
              saving: saveState.value.$1,
              savedAt: saveState.value.$2,
              onBack: () => Navigator.of(context).maybePop(),
              onOpenToc: () => showChapterTocSheet(
                context,
                chapters: chapters,
                selectedChapterId: selectedChapterId.value,
                onSelect: (id) => selectedChapterId.value = id,
                onCreateChapter: () async {
                  final order = await service.getNextSiblingOrderAtRoot();
                  final id = await service.createChapter(
                    siblingOrder: order,
                    title: '',
                  );
                  if (context.mounted) {
                    selectedChapterId.value = id;
                  }
                },
              ),
              onOpenCharacters: () =>
                  _showCharactersSheet(context, characters: characters),
              onMore: (position) {
                final chapter = activeChapter;
                if (chapter == null) {
                  return;
                }
                _showChapterMoreMenu(
                  context: context,
                  ref: ref,
                  position: position,
                  novel: novel,
                  databasePath: databasePath,
                  chapter: chapter,
                  chapters: chapters,
                  title: titleController.text,
                  content: bodyController.text,
                  onCopy: () {
                    showChapterCopyReplace(
                      context,
                      contentController: bodyController,
                    );
                  },
                  onReplace: () {
                    showChapterPunctuationReplace(
                      context,
                      contentController: bodyController,
                      onReplace: (replaced) async {
                        session.autoSaveTimer?.cancel();
                        final id = session.loadedChapterId;
                        if (id == null) {
                          throw StateError(
                            'The active chapter is no longer available.',
                          );
                        }
                        bodyController.value = TextEditingValue(
                          text: replaced,
                          selection: TextSelection.collapsed(
                            offset: replaced.length,
                          ),
                        );
                        session.markEdited(_ChapterEditField.content);
                        wordCount.value = _countChars(replaced);
                        await persist(
                          id,
                          outlineController.text,
                          titleController.text,
                          replaced,
                          rethrowOnFailure: true,
                        );
                      },
                    );
                  },
                  flushSave: () async {
                    session.autoSaveTimer?.cancel();
                    final id = session.loadedChapterId;
                    if (id != null) {
                      await persist(
                        id,
                        outlineController.text,
                        titleController.text,
                        bodyController.text,
                      );
                    }
                  },
                );
              },
            ),
            Expanded(
              child: activeChapter == null
                  ? const Center(child: CircularProgressIndicator())
                  : _ChapterSurface(
                      activeChapter: activeChapter,
                      highlightSelection: ChapterHighlightSelection(
                        path: databasePath,
                        chapterId: activeChapter.id,
                        savedBody: activeChapter.content,
                        flush: flushPendingEdit,
                      ),
                      chapters: chapters,
                      titleController: titleController,
                      bodyController: bodyController,
                      onOpenOutline: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => _ChapterOutlineEditorPage(
                            controller: outlineController,
                          ),
                        ),
                      ),
                      entityCatalog: entityCatalog,
                      onChanged: (field) {
                        if (field == _ChapterEditField.content) {
                          wordCount.value = _countChars(bodyController.text);
                        }
                        scheduleSave(field);
                      },
                    ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _EditorToolbar(
        wordCount: wordCount.value,
        saving: saveState.value.$1,
        savedAt: saveState.value.$2,
        onHistory: () {
          final chapter = activeChapter;
          if (chapter == null) {
            return;
          }
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => MobileChapterHistoryPage(
                novelId: novel.id,
                databasePath: databasePath,
                resourceId: chapter.id,
                resourceLabel: (chapter.title?.isNotEmpty ?? false)
                    ? chapter.title!
                    : context.t(LocaleKeys.workspaceChapterTitle),
              ),
            ),
          );
        },
        onFormat: () {
          // 与桌面 _StatusBarAutoFormatButton 一致：读取编辑器排版设置，
          // 一键对正文做段首缩进、空行和已有空格的规范化。
          final indentCount = ref.read(editorFormatIndentCountProvider);
          final blankLine =
              ref.read(editorFormatParagraphSpacingProvider) ==
              EditorParagraphSpacing.one_blank_line;
          final allowSpaces = ref.read(editorFormatAllowSpacesProvider);
          final original = bodyController.text;
          final formatted = formatText(
            original,
            indentCount: indentCount,
            blankLineBetweenParagraphs: blankLine,
            allowSpaces: allowSpaces,
          );
          if (formatted == original) {
            return;
          }
          // 程序化写回 controller 不会触发 TextField.onChanged，需手动触发
          // 与 onChanged 一致的字数更新 + 防抖保存（桌面用 controller listener 监听）。
          bodyController.value = TextEditingValue(
            text: formatted,
            selection: TextSelection.collapsed(offset: formatted.length),
          );
          wordCount.value = _countChars(bodyController.text);
          scheduleSave(_ChapterEditField.content);
        },
        onOpenAssistant: openAssistant,
      ),
    );
  }
}

Future<void> _showChapterMoreMenu({
  required BuildContext context,
  required WidgetRef ref,
  required Offset position,
  required Novel novel,
  required String databasePath,
  required Chapter chapter,
  required List<Chapter> chapters,
  required String title,
  required String content,
  required VoidCallback onCopy,
  required VoidCallback onReplace,
  required Future<void> Function() flushSave,
}) async {
  final colors = RevericTheme.colorsOf(context);
  final isPublished = chapter.stat == chapterStatPublished;
  final showPublishActions = !chapter.isVolume;

  final entries = <RevericMenuEntry>[
    RevericMenuItem(
      icon: RevericIcons.visibility_outlined,
      label: context.t(LocaleKeys.workspacePreview),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => MobileChapterPreviewPage(
              chapterTitle: title,
              chapterContent: content,
            ),
          ),
        );
      },
    ),
    RevericMenuItem(
      icon: RevericIcons.copy_outlined,
      label: context.t(LocaleKeys.workspaceChapterCopy),
      onTap: onCopy,
    ),
    RevericMenuItem(
      icon: RevericIcons.swap_horiz_rounded,
      label: context.t(LocaleKeys.workspaceChapterReplace),
      onTap: onReplace,
    ),
    RevericMenuItem(
      icon: RevericIcons.auto_fix_high_outlined,
      label: context.t(LocaleKeys.workspaceChapterFormatAll),
      onTap: () => _formatAllChapters(
        context,
        novel: novel,
        ref: ref,
        databasePath: databasePath,
        flushSave: flushSave,
      ),
    ),
    RevericMenuItem(
      icon: RevericIcons.text_fields_outlined,
      label: context.t(LocaleKeys.settingsFonts),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const MobileEditorSettingsPage(),
          ),
        );
      },
    ),
    if (showPublishActions && !isPublished)
      RevericMenuItem(
        icon: RevericIcons.check_circle_outline,
        iconColor: colors.additionBorder,
        label: context.t(LocaleKeys.chapterPublish),
        onTap: () => _confirmPublishChapter(
          context,
          ref: ref,
          novel: novel,
          databasePath: databasePath,
          chapter: chapter,
          chapters: chapters,
          content: content,
          flushSave: flushSave,
        ),
      ),
    if (showPublishActions && isPublished)
      RevericMenuItem(
        icon: RevericIcons.arrow_counter_clockwise,
        iconColor: colors.textMuted,
        label: context.t(LocaleKeys.chapterUnpublish),
        onTap: () async {
          await flushSave();
          if (!context.mounted) {
            return;
          }
          await ref
              .read(
                workContentServiceProvider((
                  path: databasePath,
                  novelId: novel.id,
                )),
              )
              .updateChapterStat(chapterId: chapter.id, stat: chapterStatDraft);
        },
      ),
  ];

  await showRevericContextMenu(
    context: context,
    position: position,
    minWidth: 200,
    entries: entries,
  );
}

/// 全书章节正文一键排版：先冲刷当前章未保存改动，再按排版设置批量直写。
Future<void> _formatAllChapters(
  BuildContext context, {
  required WidgetRef ref,
  required Novel novel,
  required String databasePath,
  required Future<void> Function() flushSave,
}) async {
  await flushSave();
  if (!context.mounted) {
    return;
  }
  final service = ref.read(
    workContentServiceProvider((path: databasePath, novelId: novel.id)),
  );
  final indentCount = ref.read(editorFormatIndentCountProvider);
  final blankLine =
      ref.read(editorFormatParagraphSpacingProvider) ==
      EditorParagraphSpacing.one_blank_line;
  final allowSpaces = ref.read(editorFormatAllowSpacesProvider);
  final chapterIds = await service.getChapterIdsWithContent();
  if (!context.mounted) {
    return;
  }
  final pendingCount = chapterIds.length;
  if (pendingCount == 0) {
    return;
  }
  final confirmed = await showConfirmDialog(
    context,
    title: context.t(LocaleKeys.workspaceChapterFormatConfirmTitle),
    message: context.t(
      LocaleKeys.workspaceChapterFormatConfirmMessage,
      namedArgs: {'count': '$pendingCount'},
    ),
  );
  if (!confirmed || !context.mounted) {
    return;
  }
  final (count, error) = await showFormatAllProgressDialog(
    context,
    run: (onProgress) => formatAllChapterContents(
      contentService: service,
      chapterIds: chapterIds,
      indentCount: indentCount,
      blankLineBetweenParagraphs: blankLine,
      allowSpaces: allowSpaces,
      onProgress: onProgress,
    ),
  );
  if (!context.mounted) {
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        error != null
            ? context.t(
                LocaleKeys.workspaceChapterFormatFailed,
                namedArgs: {'count': '$count'},
              )
            : context.t(
                LocaleKeys.workspaceChapterFormatDone,
                namedArgs: {'count': '$count'},
              ),
      ),
    ),
  );
}

void _confirmPublishChapter(
  BuildContext context, {
  required WidgetRef ref,
  required Novel novel,
  required String databasePath,
  required Chapter chapter,
  required List<Chapter> chapters,
  required String content,
  required Future<void> Function() flushSave,
}) {
  final colors = RevericTheme.colorsOf(context);
  final typo = RevericTheme.typographyOf(context);
  final chapterLabel = _chapterDisplayLabel(context, chapter, chapters);
  final canRunChronicler = content.trim().isNotEmpty;

  var useChronicler = canRunChronicler;

  showRevericDialog<void>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          return RevericDialog(
            title: context.t(LocaleKeys.chapterPublish),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  chapterLabel,
                  style: typo.ui.copyWith(color: colors.textSecondary),
                ),
                if (canRunChronicler) ...[
                  const SizedBox(height: RevericSpacing.md),
                  Row(
                    children: [
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: RevericCheckbox(
                          value: useChronicler,
                          onChanged: (value) {
                            setDialogState(() {
                              useChronicler = value;
                            });
                          },
                        ),
                      ),
                      const SizedBox(width: RevericSpacing.sm),
                      GestureDetector(
                        onTap: () {
                          setDialogState(() {
                            useChronicler = !useChronicler;
                          });
                        },
                        child: Text(
                          context.t(LocaleKeys.chapterRunChronicler),
                          style: typo.ui.copyWith(color: colors.textPrimary),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
            actions: [
              RevericButton.secondary(
                label: context.t(LocaleKeys.commonCancel),
                onPressed: () => Navigator.of(dialogContext).pop(),
              ),
              RevericButton.primary(
                label: context.t(LocaleKeys.chapterPublish),
                onPressed: () async {
                  Navigator.of(dialogContext).pop();
                  await _publishChapter(
                    context,
                    ref: ref,
                    novel: novel,
                    databasePath: databasePath,
                    chapter: chapter,
                    chapters: chapters,
                    useChronicler: canRunChronicler && useChronicler,
                    flushSave: flushSave,
                  );
                },
              ),
            ],
          );
        },
      );
    },
  );
}

Future<void> _publishChapter(
  BuildContext context, {
  required WidgetRef ref,
  required Novel novel,
  required String databasePath,
  required Chapter chapter,
  required List<Chapter> chapters,
  required bool useChronicler,
  required Future<void> Function() flushSave,
}) async {
  await flushSave();
  if (!context.mounted) {
    return;
  }

  await ref
      .read(workContentServiceProvider((path: databasePath, novelId: novel.id)))
      .updateChapterStat(chapterId: chapter.id, stat: chapterStatPublished);

  if (!useChronicler || !context.mounted) {
    return;
  }

  final chapterTitle = _chapterTitleForHandoff(context, chapter);
  final actionLabel = context.t(LocaleKeys.chapterRunChronicler);
  final chroniclerPrompt = context.t(LocaleKeys.chapterPublishChroniclerPrompt);

  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MobileNovelChatPage(
        novelId: novel.id,
        databasePath: databasePath,
        chapterId: chapter.id,
        chapterTitle: chapter.title,
        chapterNumber: _resolveActiveChapterNumber(chapter, chapters),
        handoff: PendingChatHandoff(
          label: actionLabel,
          content: chroniclerPrompt,
          initialText: chroniclerPrompt,
          autoSend: true,
          references: [
            AiContextReference(
              section: NovelWorkspaceSection.chapters,
              itemId: chapter.id,
              label: chapterTitle,
            ),
          ],
        ),
      ),
    ),
  );
}

String _chapterTitleForHandoff(BuildContext context, Chapter chapter) {
  final title = chapter.title?.trim() ?? '';
  if (title.isNotEmpty) {
    return title;
  }
  if (chapter.isExtra) {
    return context.t(LocaleKeys.workspaceExtra);
  }
  return context.t(
    LocaleKeys.commonChapterNumber,
    namedArgs: {'number': '${chapter.chapterNum ?? "?"}'},
  );
}

String _chapterDisplayLabel(
  BuildContext context,
  Chapter chapter,
  List<Chapter> chapters,
) {
  final title = chapter.title?.trim() ?? '';
  if (chapter.isExtra) {
    return title.isEmpty ? context.t(LocaleKeys.workspaceExtra) : title;
  }
  final chapterNumber = _chapterDisplayNumber(chapter, chapters);
  return '${context.t(LocaleKeys.commonChapterNumber, namedArgs: {'number': '${chapterNumber ?? "?"}'})} $title'
      .trim();
}

/// 解析当前编辑章节的全局章号。
///
/// 正文流走 [ChapterDao.watchContentById]，直查原表、不含 VIEW 计算列
/// chapter_num，因此优先从章节树（[ChapterDao.watchTree]，含计算章号）的
/// 同 id meta 取值，取不到再回退到 chapter 自带值。
int? _resolveActiveChapterNumber(Chapter chapter, List<Chapter> chapters) {
  for (final meta in chapters) {
    if (meta.id == chapter.id) {
      return meta.chapterNum ?? chapter.chapterNum;
    }
  }
  return chapter.chapterNum;
}

int? _chapterDisplayNumber(Chapter chapter, List<Chapter> chapters) {
  if (chapter.isExtra) {
    return null;
  }
  if (chapter.parentId == null) {
    return chapter.chapterNum;
  }
  return chapter.volumeChapterNum ?? chapter.chapterNum;
}

/// 章节编辑页标题栏：返回 + 作品名/章号·保存状态 + 目录/角色/更多。
class _ChapterEditorHeader extends StatelessWidget {
  const _ChapterEditorHeader({
    required this.novel,
    required this.activeChapter,
    required this.chapterNumber,
    required this.saving,
    required this.savedAt,
    required this.onBack,
    required this.onOpenToc,
    required this.onOpenCharacters,
    required this.onMore,
  });

  final Novel novel;
  final Chapter? activeChapter;
  final int? chapterNumber;
  final bool saving;
  final DateTime? savedAt;
  final VoidCallback onBack;
  final VoidCallback onOpenToc;
  final VoidCallback onOpenCharacters;
  final void Function(Offset globalPosition) onMore;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    final ch = activeChapter;
    final chapterLabel = ch == null
        ? ''
        : (chapterNumber != null
              ? context.t(
                  LocaleKeys.commonChapterNumber,
                  namedArgs: {'number': '$chapterNumber'},
                )
              : ch.displayTitle);
    final status = saving
        ? context.t(LocaleKeys.mobileEditorSaving)
        : (savedAt != null ? context.t(LocaleKeys.commonSaved) : '');
    final subtitle = [
      chapterLabel,
      status,
    ].where((s) => s.isNotEmpty).join(' · ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.xs,
        RevericSpacing.sm,
        RevericSpacing.xs,
        RevericSpacing.sm,
      ),
      child: Row(
        children: [
          _HeaderIconButton(icon: RevericIcons.arrow_back, onTap: onBack),
          Expanded(
            child: Column(
              children: [
                Text(
                  novel.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: typo.uiSemibold.copyWith(color: colors.textPrimary),
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: typo.uiTiny.copyWith(color: colors.textMuted),
                  ),
                ],
              ],
            ),
          ),
          _HeaderIconButton(
            icon: RevericIcons.list_alt_outlined,
            onTap: onOpenToc,
          ),
          _HeaderIconButton(icon: RevericIcons.person, onTap: onOpenCharacters),
          _HeaderIconButton(icon: RevericIcons.more_horiz, onTapDown: onMore),
        ],
      ),
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({required this.icon, this.onTap, this.onTapDown})
    : assert(onTap != null || onTapDown != null);

  final String icon;
  final VoidCallback? onTap;
  final void Function(Offset globalPosition)? onTapDown;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return GestureDetector(
      onTap: onTap,
      onTapDown: onTapDown == null
          ? null
          : (details) => onTapDown!(details.globalPosition),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(RevericSpacing.sm),
        child: RevericIcon(icon, size: 22, color: colors.textSecondary),
      ),
    );
  }
}

/// 移动端正文字段：`expands` 时 [TextField] 在内部滚动，划线层需跟随
/// [ScrollController.offset] 同步平移。
class _MobileChapterBodyField extends StatefulWidget {
  const _MobileChapterBodyField({
    required this.chapterId,
    required this.controller,
    required this.onChanged,
    required this.lineEnabled,
    required this.lineNumbersEnabled,
    required this.lineStyle,
    required this.lineColorHex,
    required this.editorFontFamily,
    required this.editorFontSize,
    required this.editorLineHeight,
    required this.bodyStyle,
    required this.hintStyle,
    required this.contextMenuBuilder,
  });

  final String chapterId;
  final TextEditingController controller;
  final VoidCallback onChanged;
  final bool lineEnabled;
  final bool lineNumbersEnabled;
  final EditorLineStyle lineStyle;
  final String lineColorHex;
  final String editorFontFamily;
  final int editorFontSize;
  final double editorLineHeight;
  final TextStyle bodyStyle;
  final TextStyle hintStyle;
  final EditableTextContextMenuBuilder contextMenuBuilder;

  @override
  State<_MobileChapterBodyField> createState() =>
      _MobileChapterBodyFieldState();
}

class _MobileChapterBodyFieldState extends State<_MobileChapterBodyField> {
  late final ScrollController _scrollController;
  late List<TextInputFormatter> _inputFormatters = _createInputFormatters();
  // 挂在正文 TextField 上，供划线层定位其内部 RenderEditable 读取真实行几何。
  final GlobalKey _fieldKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
  }

  @override
  void didUpdateWidget(covariant _MobileChapterBodyField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chapterId != widget.chapterId ||
        oldWidget.controller != widget.controller) {
      _inputFormatters = _createInputFormatters();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _handlePasteRejected(int chars) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          context.t(
            LocaleKeys.editorPasteTooLarge,
            namedArgs: {'chars': '$chars'},
          ),
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  List<TextInputFormatter> _createInputFormatters() => [
    ChapterParagraphIndentFormatter(),
    PasteSizeLimitTextInputFormatter(onRejected: _handlePasteRejected),
  ];

  @override
  Widget build(BuildContext context) {
    final strutStyle = StrutStyle(
      fontSize: widget.editorFontSize.toDouble(),
      height: widget.editorLineHeight,
      fontFamily: widget.editorFontFamily,
      leadingDistribution: TextLeadingDistribution.even,
      forceStrutHeight: true,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            Focus(
              skipTraversal: true,
              canRequestFocus: false,
              onKeyEvent: (node, event) => handleChapterTabKeyEvent(
                controller: widget.controller,
                event: event,
                onChanged: widget.onChanged,
              ),
              child: TextField(
                key: _fieldKey,
                controller: widget.controller,
                contextMenuBuilder: widget.contextMenuBuilder,
                scrollController: _scrollController,
                onChanged: (_) => widget.onChanged(),
                inputFormatters: _inputFormatters,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                keyboardType: TextInputType.multiline,
                strutStyle: strutStyle,
                style: widget.bodyStyle,
                decoration: InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  contentPadding: widget.lineNumbersEnabled
                      ? const EdgeInsets.only(
                          left: editorLineNumbersGutterWidth,
                        )
                      : EdgeInsets.zero,
                  hintText: context.t(LocaleKeys.mobileEditorBodyHint),
                  hintStyle: widget.hintStyle,
                ),
              ),
            ),
            if (widget.lineEnabled)
              MobileEditorFocusLines(
                fieldKey: _fieldKey,
                controller: widget.controller,
                scrollController: _scrollController,
                lineStyle: widget.lineStyle,
                lineColor: parseMobileEditorLineColorHex(widget.lineColorHex),
              ),
            if (widget.lineNumbersEnabled)
              Positioned.fill(
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: SizedBox(
                    width: editorLineNumbersGutterWidth,
                    child: EditorLineNumbers(
                      controller: widget.controller,
                      scrollController: _scrollController,
                      contentStyle: widget.bodyStyle,
                      numberStyle: RevericTheme.typographyOf(context).uiTiny
                          .copyWith(
                            color: RevericTheme.colorsOf(context).textSubtle,
                          ),
                      lineHeight: widget.editorLineHeight,
                      width: editorLineNumbersGutterWidth,
                      contentWidth:
                          constraints.maxWidth - editorLineNumbersGutterWidth,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ChapterSurface extends ConsumerWidget {
  const _ChapterSurface({
    required this.activeChapter,
    required this.highlightSelection,
    required this.chapters,
    required this.titleController,
    required this.bodyController,
    required this.onOpenOutline,
    required this.entityCatalog,
    required this.onChanged,
  });

  final Chapter activeChapter;
  final ChapterHighlightSelection highlightSelection;
  final List<Chapter> chapters;
  final TextEditingController titleController;
  final ChapterDialogueHighlightController bodyController;
  final VoidCallback onOpenOutline;
  final List<ChapterEntityMention> entityCatalog;

  /// 按字段上报编辑，让父级分别标脏——标题与正文各自独立，
  /// 才能做到「用户改标题时 AI 改正文」两边都不丢。
  final ValueChanged<_ChapterEditField> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final editorFontFamily = ref.watch(editorFontFamilyProvider);
    final editorFontSize = ref.watch(editorFontSizeProvider);
    final editorFontColor = ref.watch(editorFontColorProvider);
    final editorLetterSpacing = ref.watch(editorLetterSpacingProvider);
    final editorLineHeight = ref.watch(editorLineHeightProvider);
    final lineEnabled = ref.watch(editorLineEnabledProvider);
    final lineNumbersEnabled = ref.watch(editorLineNumbersEnabledProvider);
    final lineStyle = ref.watch(editorLineStyleProvider);
    final lineColorHex = ref.watch(editorLineColorHexProvider);
    bodyController
      ..dialogueHighlightEnabled = ref.watch(
        editorDialogueHighlightEnabledProvider,
      )
      ..highlightBackground =
          ref.watch(editorHighlightColorProvider) ??
          colors.editorHighlightBackground;
    highlightSelection.configure(ref, bodyController);

    final volume = _volumeOf(activeChapter, chapters);
    final chapterNumber = _resolveActiveChapterNumber(activeChapter, chapters);
    final chapterLabel = chapterNumber != null
        ? context.t(
            LocaleKeys.commonChapterNumber,
            namedArgs: {'number': '$chapterNumber'},
          )
        : activeChapter.displayTitle;

    // 正文中识别到的实体（去重、保持首次出现顺序）。
    final mentioned = _dedupMentions(
      findChapterEntityMatches(bodyController.text, entityCatalog),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        RevericSpacing.x4l,
        RevericSpacing.lg,
        RevericSpacing.x4l,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (volume != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: RevericSpacing.sm,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colors.accentWarm.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(RevericRadius.pill),
                  ),
                  child: Text(
                    volume.displayTitle,
                    style: typo.uiTinySemibold.copyWith(
                      color: colors.accentWarm,
                    ),
                  ),
                ),
                const SizedBox(width: RevericSpacing.sm),
              ],
              Text(
                chapterLabel,
                style: typo.uiTiny.copyWith(color: colors.textSubtle),
              ),
            ],
          ),
          const SizedBox(height: RevericSpacing.sm),
          TextField(
            controller: titleController,
            onChanged: (_) => onChanged(_ChapterEditField.title),
            maxLines: 1,
            textInputAction: TextInputAction.next,
            style: typo.display.copyWith(color: colors.textPrimary),
            decoration: InputDecoration(
              isCollapsed: true,
              border: InputBorder.none,
              hintText: context.t(LocaleKeys.mobileEditorChapterTitleHint),
              hintStyle: typo.display.copyWith(color: colors.textSubtle),
            ),
          ),
          const SizedBox(height: RevericSpacing.md),
          _ChapterOutlineField(onTap: onOpenOutline),
          if (mentioned.isNotEmpty) ...[
            const SizedBox(height: RevericSpacing.md),
            _MentionedEntitiesRow(mentions: mentioned),
          ],
          const SizedBox(height: RevericSpacing.md),
          Expanded(
            child: _MobileChapterBodyField(
              chapterId: activeChapter.id,
              controller: bodyController,
              contextMenuBuilder: (context, editable) {
                final highlightItems = highlightSelection.menuItems(
                  editable.context,
                  ref,
                  bodyController,
                );
                if (highlightItems.isEmpty) {
                  return AdaptiveTextSelectionToolbar.editableText(
                    editableTextState: editable,
                  );
                }
                return AdaptiveTextSelectionToolbar.buttonItems(
                  anchors: editable.contextMenuAnchors,
                  buttonItems: [
                    ...highlightItems,
                    ...editable.contextMenuButtonItems,
                  ],
                );
              },
              onChanged: () => onChanged(_ChapterEditField.content),
              lineEnabled: lineEnabled,
              lineNumbersEnabled: lineNumbersEnabled,
              lineStyle: lineStyle,
              lineColorHex: lineColorHex,
              editorFontFamily: editorFontFamily,
              editorFontSize: editorFontSize,
              editorLineHeight: editorLineHeight,
              bodyStyle: typo.body.copyWith(
                color: editorFontColor ?? colors.textPrimary,
                height: editorLineHeight,
                fontFamily: editorFontFamily,
                fontSize: editorFontSize.toDouble(),
                letterSpacing: editorLetterSpacing,
              ),
              hintStyle: typo.body.copyWith(
                color: colors.textSubtle,
                height: editorLineHeight,
                fontFamily: editorFontFamily,
                fontSize: editorFontSize.toDouble(),
                letterSpacing: editorLetterSpacing,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Chapter? _volumeOf(Chapter chapter, List<Chapter> chapters) {
    final parentId = chapter.parentId;
    if (parentId == null) {
      return null;
    }
    for (final c in chapters) {
      if (c.id == parentId && c.isVolume) {
        return c;
      }
    }
    return null;
  }
}

/// 按实体 id 去重，保持首次出现顺序。
List<ChapterEntityMention> _dedupMentions(List<ChapterEntityMatch> matches) {
  final seen = <String>{};
  final result = <ChapterEntityMention>[];
  for (final match in matches) {
    final key = '${match.entity.entityType}:${match.entity.id}';
    if (seen.add(key)) {
      result.add(match.entity);
    }
  }
  return result;
}

/// 章节大纲入口。移动端用独立页面编辑，避免长文本编辑区挤占正文。
class _ChapterOutlineField extends StatelessWidget {
  const _ChapterOutlineField({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(RevericRadius.xl),
        border: Border.all(color: colors.borderSubtle),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: colors.surfaceContainerHigh,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  RevericSpacing.x2l,
                  RevericSpacing.md,
                  RevericSpacing.lg,
                  RevericSpacing.md,
                ),
                child: Row(
                  children: [
                    RevericIcon(
                      RevericIcons.timeline_outlined,
                      size: 16,
                      color: colors.textMuted,
                    ),
                    const SizedBox(width: RevericSpacing.sm),
                    Text(
                      context.t(LocaleKeys.workspaceChapterOutline),
                      style: typo.uiSemibold.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      context.t(LocaleKeys.commonEdit),
                      style: typo.uiSmallSemibold.copyWith(
                        color: colors.accent,
                      ),
                    ),
                    const SizedBox(width: RevericSpacing.xs),
                    RevericIcon(
                      RevericIcons.chevron_right,
                      size: 16,
                      color: colors.textMuted,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChapterOutlineEditorPage extends HookWidget {
  const _ChapterOutlineEditorPage({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final focusNode = useFocusNode();

    return Scaffold(
      backgroundColor: colors.canvas,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                RevericSpacing.xs,
                RevericSpacing.sm,
                RevericSpacing.x2l,
                RevericSpacing.sm,
              ),
              child: Row(
                children: [
                  _HeaderIconButton(
                    icon: RevericIcons.arrow_back,
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                  Expanded(
                    child: Text(
                      context.t(LocaleKeys.workspaceChapterOutline),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typo.uiSemibold.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  RevericSpacing.x4l,
                  RevericSpacing.lg,
                  RevericSpacing.x4l,
                  RevericSpacing.x4l,
                ),
                child: RevericMarkdownEditor(
                  controller: controller,
                  focusNode: focusNode,
                  hintText: context.t(LocaleKeys.workspaceOutlineContentHint),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「本章提及」实体 chip 横向滚动条；点击 chip 弹出实体卡片。
class _MentionedEntitiesRow extends StatelessWidget {
  const _MentionedEntitiesRow({required this.mentions});

  final List<ChapterEntityMention> mentions;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: mentions.length,
        separatorBuilder: (_, _) => const SizedBox(width: RevericSpacing.xs),
        itemBuilder: (context, index) {
          final entity = mentions[index];
          final accent = entityAccentColor(entity.entityType, colors);
          return InkWell(
            onTap: () => _showEntityCardSheet(context, entity),
            borderRadius: BorderRadius.circular(RevericRadius.pill),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: RevericSpacing.lg,
              ),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(RevericRadius.pill),
                border: Border.all(color: accent.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  RevericIcon(
                    entityIcon(entity.entityType),
                    size: 14,
                    color: accent,
                  ),
                  const SizedBox(width: RevericSpacing.xs),
                  Text(
                    entity.label,
                    style: typo.uiSmallSemibold.copyWith(color: accent),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 角色面板：底部弹层列出全部角色小传卡片。
void _showCharactersSheet(
  BuildContext context, {
  required List<CharacterProfile> characters,
}) {
  final enabled =
      characters.where((c) => c.deletedAt == notDeletedSentinel).toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) {
      final colors = RevericTheme.colorsOf(sheetContext);
      final typo = RevericTheme.typographyOf(sheetContext);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            RevericSpacing.x4l,
            0,
            RevericSpacing.x4l,
            RevericSpacing.x4l,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                sheetContext.t(LocaleKeys.mobileEditorCharactersTitle),
                style: typo.heading2.copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: RevericSpacing.x3l),
              if (enabled.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: RevericSpacing.x4l,
                  ),
                  child: Center(
                    child: Text(
                      sheetContext.t(LocaleKeys.mobileEditorNoCharacters),
                      style: typo.uiSmall.copyWith(color: colors.textMuted),
                    ),
                  ),
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    itemCount: enabled.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: RevericSpacing.md),
                    itemBuilder: (_, index) {
                      final character = enabled[index];
                      return InkWell(
                        onTap: () => _showEntityCardSheet(
                          sheetContext,
                          characterEntityMention(character),
                        ),
                        borderRadius: BorderRadius.circular(
                          RevericRadius.large,
                        ),
                        child: _CharacterPanelCard(character: character),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

/// 角色面板中的单条角色卡片：头像 + 名称 + 角色标签 + 摘要。
class _CharacterPanelCard extends StatelessWidget {
  const _CharacterPanelCard({required this.character});

  final CharacterProfile character;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final roleLabel = characterRoleLabel(context, character.normalizedRole);
    final summary = character.biographyPreview.trim();

    return Container(
      padding: const EdgeInsets.all(RevericSpacing.lg),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(RevericRadius.large),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CharacterAvatar(
            character: character,
            size: 40,
            backgroundColor: colors.accent.withValues(alpha: 0.2),
            textColor: colors.accent,
          ),
          const SizedBox(width: RevericSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  character.name,
                  style: typo.uiSemibold.copyWith(color: colors.textPrimary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: RevericSpacing.xxs),
                Text(
                  roleLabel,
                  style: typo.uiTiny.copyWith(color: colors.textMuted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (summary.isNotEmpty) ...[
                  const SizedBox(height: RevericSpacing.xs),
                  Text(
                    summary,
                    style: typo.uiSmall.copyWith(
                      color: colors.textSecondary,
                      height: 1.45,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 实体卡片底部弹层，供提及 chip 与角色面板条目共用。
void _showEntityCardSheet(BuildContext context, ChapterEntityMention entity) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) {
      final colors = RevericTheme.colorsOf(sheetContext);
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            RevericSpacing.x4l,
            0,
            RevericSpacing.x4l,
            RevericSpacing.x5l,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(RevericRadius.large),
            ),
            child: EntityCard(entity: entity),
          ),
        ),
      );
    },
  );
}

class _EditorToolbar extends StatelessWidget {
  const _EditorToolbar({
    required this.wordCount,
    required this.saving,
    required this.savedAt,
    required this.onHistory,
    required this.onFormat,
    required this.onOpenAssistant,
  });

  final int wordCount;
  final bool saving;
  final DateTime? savedAt;
  final VoidCallback onHistory;
  final VoidCallback onFormat;
  final VoidCallback onOpenAssistant;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    final statusText = saving
        ? context.t(LocaleKeys.mobileEditorSaving)
        : (savedAt != null
              ? context.t(
                  LocaleKeys.mobileEditorAutosaveAt,
                  namedArgs: {'time': _formatTime(savedAt!)},
                )
              : '');

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.borderSubtle)),
      ),
      padding: EdgeInsets.fromLTRB(
        RevericSpacing.x2l,
        RevericSpacing.md,
        RevericSpacing.x2l,
        bottomInset + RevericSpacing.lg,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  context.t(
                    LocaleKeys.mobileEditorWordCount,
                    namedArgs: {'count': '$wordCount'},
                  ),
                  style: typo.uiSmallSemibold.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                if (statusText.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    statusText,
                    style: typo.uiTiny.copyWith(color: colors.textSubtle),
                  ),
                ],
              ],
            ),
          ),
          _ToolbarIconButton(
            icon: RevericIcons.history_outlined,
            tooltip: context.t(LocaleKeys.historyOpen),
            onTap: onHistory,
          ),
          const SizedBox(width: RevericSpacing.sm),
          _ToolbarIconButton(
            icon: RevericIcons.auto_fix_high_outlined,
            tooltip: context.t(LocaleKeys.workspaceChapterAutoFormat),
            onTap: onFormat,
          ),
          const SizedBox(width: RevericSpacing.sm),
          FilledButton.icon(
            onPressed: onOpenAssistant,
            icon: RevericIcon(
              RevericIcons.auto_awesome,
              size: 18,
              color: colors.onAccent,
            ),
            label: Text(context.t(LocaleKeys.mobileEditorAiAssistant)),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

class _ToolbarIconButton extends StatelessWidget {
  const _ToolbarIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final String icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(RevericRadius.x2l),
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(RevericRadius.x2l),
            border: Border.all(color: colors.borderSubtle),
          ),
          child: Center(
            child: RevericIcon(icon, size: 20, color: colors.textSecondary),
          ),
        ),
      ),
    );
  }
}
