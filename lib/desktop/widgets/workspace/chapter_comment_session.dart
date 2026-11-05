// 职责: 章节批注的状态与行为所有者 — 解析锚点、开合气泡、增改解决与删除。
// 关联文件:
//   lib/desktop/widgets/workspace/chapter_editor.dart
//   lib/shared/models/chapter_comment.dart
//   lib/shared/utils/chapter_comment_anchor.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/services/novel_content.dart
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/state-management.md

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../shared/models/chapter_comment.dart';
import '../../../shared/providers/novel_providers.dart';
import '../../../shared/utils/chapter_comment_anchor.dart';
import '../../../shared/utils/random_id.dart';

/// 正在新建、尚未落库的一条批注。
@immutable
class ChapterCommentDraft {
  const ChapterCommentDraft({
    required this.start,
    required this.end,
    required this.quote,
  });

  final int start;
  final int end;
  final String quote;
}

/// 一章批注的读写门面。
///
/// 存在的理由是边界而不是省代码：批注的状态（当前打开哪条、正在新建什么）和行为
/// （增/改/解决/删）是一簇内聚的东西，塞进 [ChapterEditor] 的构造参数就是参数袋。
/// 这里把它们收成一个带方法的对象，向下只暴露行为。
///
/// 写入直接落 `NovelContentService`，刷新靠章节自己的 watch 流回流，不另设 Notifier
/// （`.agents/rules/state-management.md` 模式 1：Stream 读 + Service 写）。
class ChapterCommentSession {
  ChapterCommentSession({
    required this.enabled,
    required this.comments,
    required this.draft,
    required this._activeComment,
    required this._onOpenDraft,
    required this._onOpenThread,
    required this._onDismiss,
    required this._onCancel,
    required this._onSubmit,
    required this._onContentChanged,
    required this._onToggleResolved,
    required this._onDelete,
  });

  /// 没有 databasePath / chapterId 时整套批注功能关闭。
  final bool enabled;

  /// 本章未删除的批注原始列表（锚点未校准）。
  ///
  /// 校准放在渲染侧做：正文在编辑器内逐键变化，只有那里拿得到最新文本
  /// （见 [resolveChapterComments]）。这里保持存储原样，避免两处解析打架。
  final List<ChapterComment> comments;

  /// 新建中的选区；没有在新建则为 null。
  final ChapterCommentDraft? draft;

  final ChapterComment? _activeComment;
  final void Function(int start, int end, String quote) _onOpenDraft;
  final void Function(String id) _onOpenThread;
  final Future<void> Function() _onDismiss;
  final VoidCallback _onCancel;
  final Future<void> Function(String content) _onSubmit;
  final ValueChanged<String> _onContentChanged;
  final Future<void> Function() _onToggleResolved;
  final Future<void> Function() _onDelete;

  bool get hasPopover => draft != null || _activeComment != null;

  ChapterComment? get activeComment => _activeComment;

  /// 当前气泡打开的批注 id；新建中为 null。
  String? get activeId => _activeComment?.id;

  /// 气泡里要显示的原文：新建取选区，查看取批注引文。
  String get activeQuote => draft?.quote ?? _activeComment?.quote ?? '';

  int get unresolvedCount => comments.where((c) => !c.isResolved).length;

  bool get isEmpty => comments.isEmpty;

  /// 新建中的选区区间；查看既有批注时为 null（那条要按正文重新校准）。
  ChapterCommentAnchor? get draftAnchor {
    final current = draft;
    if (current == null) {
      return null;
    }
    return ChapterCommentAnchor(start: current.start, end: current.end);
  }

  void openDraft({
    required int start,
    required int end,
    required String quote,
  }) => _onOpenDraft(start, end, quote);

  void openThread(String id) => _onOpenThread(id);

  Future<void> dismiss() => _onDismiss();

  void cancel() => _onCancel();

  Future<void> submit(String content) => _onSubmit(content);

  void updateContent(String content) => _onContentChanged(content);

  Future<void> toggleResolved() => _onToggleResolved();

  Future<void> delete() => _onDelete();
}

/// 建立一章的批注会话。
///
/// [stored] 直接来自章节行（含已软删除项）。
ChapterCommentSession useChapterCommentSession({
  required WidgetRef ref,
  required String? databasePath,
  required String? chapterId,
  required List<ChapterComment>? stored,
}) {
  final activeId = useState<String?>(null);
  final draft = useState<ChapterCommentDraft?>(null);
  final editingContent = useState<String?>(null);
  final enabled = databasePath != null && chapterId != null;

  final storedComments = stored ?? const <ChapterComment>[];
  final visible = useMemoized(
    () => storedComments.where((c) => !c.isDeleted).toList(growable: false),
    [storedComments],
  );

  // 章节切换或批注被删后，指向不存在条目的 activeId 自然收敛为 null。
  final activeComment = visible
      .where((c) => c.id == activeId.value)
      .firstOrNull;

  Future<void> write(List<ChapterComment> next) async {
    if (!enabled) {
      return;
    }
    await ref
        .read(novelContentServiceProvider(databasePath))
        .updateChapterComments(chapterId: chapterId, comments: next);
  }

  Future<void> submitContent(String text) async {
    final pending = draft.value;
    final now = DateTime.now();
    editingContent.value = text;
    if (pending != null) {
      final created = ChapterComment(
        id: buildRandomId('comment'),
        start: pending.start,
        end: pending.end,
        quote: pending.quote,
        content: text,
        createdAt: now,
        updatedAt: now,
      );
      draft.value = null;
      activeId.value = created.id;
      await write([...storedComments, created]);
      return;
    }
    final current = activeComment;
    if (current == null) {
      return;
    }
    await write([
      for (final comment in storedComments)
        if (comment.id == current.id)
          comment.copyWith(content: text, updatedAt: now)
        else
          comment,
    ]);
  }

  return ChapterCommentSession(
    enabled: enabled,
    comments: visible,
    draft: draft.value,
    activeComment: activeComment,
    onOpenDraft: (start, end, quote) {
      activeId.value = null;
      draft.value = ChapterCommentDraft(start: start, end: end, quote: quote);
      editingContent.value = '';
    },
    onOpenThread: (id) {
      draft.value = null;
      activeId.value = id;
      editingContent.value = visible
          .where((comment) => comment.id == id)
          .firstOrNull
          ?.content;
    },
    onDismiss: () async {
      final current = activeComment;
      final pending = draft.value;
      final text = editingContent.value?.trim() ?? '';
      final original = current?.content.trim() ?? '';
      if (text.isNotEmpty && (pending != null || text != original)) {
        await submitContent(text);
      }
      draft.value = null;
      activeId.value = null;
      editingContent.value = null;
    },
    onCancel: () {
      draft.value = null;
      activeId.value = null;
      editingContent.value = null;
    },
    onSubmit: submitContent,
    onContentChanged: (content) {
      editingContent.value = content;
    },
    onToggleResolved: () async {
      final current = activeComment;
      if (current == null) {
        return;
      }
      final next = current.isResolved
          ? chapterCommentStatusOpen
          : chapterCommentStatusResolved;
      await write([
        for (final comment in storedComments)
          if (comment.id == current.id)
            comment.copyWith(status: next, updatedAt: DateTime.now())
          else
            comment,
      ]);
    },
    onDelete: () async {
      final current = activeComment;
      if (current == null) {
        return;
      }
      final now = DateTime.now();
      activeId.value = null;
      // 软删除（`.agents/rules/data-deletion.md`）：只打标记，不从列表里剔除。
      await write([
        for (final comment in storedComments)
          if (comment.id == current.id)
            comment.copyWith(deletedAt: now, updatedAt: now)
          else
            comment,
      ]);
    },
  );
}
