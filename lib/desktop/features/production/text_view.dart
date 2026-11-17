// 职责: 在弹窗里放大编辑文本节点的正文，关闭时保存，一次保存对应一步撤销。
// 关联文件:
//   lib/desktop/features/production/node_bar.dart
//   lib/desktop/features/production/text_node.dart
//   lib/desktop/features/production/history_region.dart
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/widgets/md/reveric_markdown_editor.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/hooks.md
//   .agents/rules/text-input-ime.md
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../../shared/components/reveric_button.dart';
import '../../../shared/components/reveric_dialog.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/logger/app_logger.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/md/reveric_markdown_editor.dart';
import 'history_region.dart';

final _log = AppLogger.forModule('ProductionTextView');

/// 先落卡片里尚未保存的正文，再在弹窗里放大编辑。
/// 弹窗路由不在画布的历史作用域下，撤销记录在打开前取好。
Future<void> showProductionTextView(
  BuildContext context,
  ProductionCanvasService service,
  CanvasNode node,
) async {
  final scope = ProductionHistoryScope.maybeOf(context);
  if (scope?.session != null && !await scope!.session!.close()) {
    return;
  }
  if (!context.mounted) {
    return;
  }
  final fresh = await service.requireNode(node.id);
  if (!context.mounted) {
    return;
  }
  await showRevericDialog<void>(
    context: context,
    builder: (context) => _TextEditorDialog(
      service: service,
      node: fresh,
      history: scope?.history,
    ),
  );
}

class _TextEditorDialog extends HookWidget {
  const _TextEditorDialog({
    required this.service,
    required this.node,
    required this.history,
  });

  final ProductionCanvasService service;
  final CanvasNode node;
  final CanvasHistory? history;

  @override
  Widget build(BuildContext context) {
    // 外部 controller 是输入期的唯一真源，关闭时一次性写入。
    final content = useTextEditingController(text: node.content);
    final focus = useFocusNode();
    final baseline = useRef(node.content);
    final writing = useRef<Future<bool>?>(null);
    final closing = useRef(false);
    final busy = useState(false);
    final typo = RevericTheme.typographyOf(context);
    useEffect(() {
      focus.requestFocus();
      return null;
    }, const []);

    Future<bool> persist() async {
      final next = content.text;
      if (next == baseline.value) {
        return true;
      }
      busy.value = true;
      try {
        await service.updateText(
          node.id,
          title: node.title,
          content: next,
          history: history,
        );
        baseline.value = next;
        return true;
      } catch (error, stack) {
        _log.error(
          'Text node save failed id=${node.id}',
          error: error,
          stackTrace: stack,
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.t(LocaleKeys.commonSaveFailed))),
          );
        }
        return false;
      } finally {
        if (context.mounted) {
          busy.value = false;
        }
      }
    }

    Future<bool> save() async {
      if (writing.value case final pending?) {
        return pending;
      }
      final future = persist();
      writing.value = future;
      try {
        return await future;
      } finally {
        writing.value = null;
      }
    }

    Future<void> close() async {
      if (closing.value) {
        return;
      }
      closing.value = true;
      final ok = await save();
      if (!ok) {
        closing.value = false;
        return;
      }
      if (context.mounted) {
        Navigator.of(context).pop();
      }
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          return;
        }
        close();
      },
      child: RevericDialog.panel(
        width: RevericSizes.mediaPreviewMaxWidth,
        title: Text(
          node.title.trim().isEmpty
              ? context.t(LocaleKeys.productionText)
              : node.title,
        ),
        content: LayoutBuilder(
          builder: (context, constraints) {
            final maxHeight = constraints.maxHeight;
            final height = maxHeight.isFinite
                ? math.min(maxHeight, RevericSizes.mediaPreviewMaxHeight)
                : RevericSizes.mediaPreviewMaxHeight;
            // 长正文走编辑器自己的虚拟列表，不用随内容增高。
            return SizedBox(
              height: height,
              width: double.infinity,
              child: RevericMarkdownEditor(
                controller: content,
                focusNode: focus,
                hintText: context.t(LocaleKeys.commonContent),
                disabled: busy.value,
                fontFamily: typo.body.fontFamily,
                fontSize: typo.body.fontSize?.round(),
                lineHeight: typo.body.height,
              ),
            );
          },
        ),
        actions: [
          RevericButton.text(
            label: context.t(LocaleKeys.commonClose),
            onPressed: busy.value ? null : close,
          ),
        ],
      ),
    );
  }
}
