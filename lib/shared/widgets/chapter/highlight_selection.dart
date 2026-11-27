// 职责: 为正文选区提供高亮操作，并将已保存标记交给编辑器绘制。
// 关联文件:
//   lib/shared/widgets/chapter/dialogue_highlight_controller.dart
//   lib/shared/providers/chapter_highlight_provider.dart
//   lib/shared/services/novel_content.dart
//   lib/shared/components/reveric_color_picker_dialog.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/chapter.json
//   assets/translations/zh-CN/chapter.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../components/reveric_color_picker_dialog.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../providers/chapter_highlight_provider.dart';
import '../../providers/novel_providers.dart';
import 'dialogue_highlight_controller.dart';

class ChapterHighlightSelection {
  const ChapterHighlightSelection({
    required this.path,
    required this.chapterId,
    required this.savedBody,
    required this.flush,
  });

  final String path;
  final String chapterId;
  final String savedBody;
  final Future<bool> Function() flush;

  ({String path, String chapterId}) get _chapter =>
      (path: path, chapterId: chapterId);

  void configure(WidgetRef ref, ChapterDialogueHighlightController controller) {
    final highlights = ref.watch(chapterHighlightsProvider(_chapter));
    controller.configureManualHighlights(
      marks: highlights.value ?? const [],
      savedBody: savedBody,
    );
  }

  List<ContextMenuButtonItem> menuItems(
    BuildContext context,
    WidgetRef ref,
    ChapterDialogueHighlightController controller,
  ) {
    final value = controller.value;
    final selection = value.selection;
    if (!selection.isValid ||
        selection.isCollapsed ||
        selection.end > value.text.length ||
        (value.composing.isValid && !value.composing.isCollapsed)) {
      return const [];
    }
    final mark = controller.highlightAt(selection);
    final failed = context.t(LocaleKeys.commonSaveFailed);
    Future<void> run(Future<void> Function() action) async {
      ContextMenuController.removeAny();
      try {
        await action();
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.maybeOf(
            context,
          )?.showSnackBar(SnackBar(content: Text(failed)));
        }
      }
    }

    Future<void> writeSelection({required bool clear}) => run(() async {
      final service = ref.read(novelContentServiceProvider(path));
      if (!await flush()) {
        throw StateError('Could not save chapter before writing highlight');
      }
      await service.writeChapterHighlight(
        chapterId: chapterId,
        expectedContent: value.text,
        selection: (start: selection.start, end: selection.end),
        clear: clear,
      );
    });

    final customColor = mark?.colorArgb;
    return [
      if (mark == null && selection.textInside(value.text).trim().isNotEmpty)
        ContextMenuButtonItem(
          label: context.t(LocaleKeys.chapterHighlightSelection),
          onPressed: () => writeSelection(clear: false),
        ),
      if (mark != null)
        ContextMenuButtonItem(
          label: context.t(LocaleKeys.chapterChangeHighlightColor),
          onPressed: () => run(() async {
            final service = ref.read(novelContentServiceProvider(path));
            final picked = await showRevericColorPickerDialog(
              context: context,
              initialColor: customColor == null
                  ? controller.highlightBackground
                  : Color(customColor),
            );
            if (picked != null) {
              await service.setChapterHighlightColor(
                chapterId: chapterId,
                highlightId: mark.id,
                colorArgb: picked.toARGB32(),
              );
            }
          }),
        ),
      if (mark != null && customColor != null)
        ContextMenuButtonItem(
          label: context.t(LocaleKeys.chapterUseDefaultHighlightColor),
          onPressed: () => run(() {
            return ref
                .read(novelContentServiceProvider(path))
                .setChapterHighlightColor(
                  chapterId: chapterId,
                  highlightId: mark.id,
                  colorArgb: null,
                );
          }),
        ),
      ContextMenuButtonItem(
        label: context.t(LocaleKeys.chapterRemoveHighlight),
        onPressed: () => writeSelection(clear: true),
      ),
    ];
  }
}
