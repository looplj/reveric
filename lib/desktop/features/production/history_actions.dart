// 职责: 在制作画布内处理撤销快捷键和动作，保留输入框编辑及未保存草稿的优先权。
// 关联文件:
//   lib/desktop/features/production/history_region.dart
//   lib/desktop/features/production/canvas_controls.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/logger/app_logger.dart';
import '../../../shared/services/production/canvas_history.dart';

final _log = AppLogger.forModule('ProductionHistory');

class ProductionUndoIntent extends Intent {
  const ProductionUndoIntent();
}

class ProductionRedoIntent extends Intent {
  const ProductionRedoIntent();
}

class ProductionHistoryActions extends HookWidget {
  const ProductionHistoryActions({
    super.key,
    required this.history,
    required this.beforeRestore,
    required this.onRestored,
    required this.child,
  });
  final CanvasHistory history;
  final Future<bool> Function() beforeRestore;
  final Future<void> Function() onRestored;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final busy = useRef(false);
    Future<void> restore(bool redo) async {
      if (busy.value || !(redo ? history.canRedo : history.canUndo)) {
        return;
      }
      busy.value = true;
      try {
        if (!await beforeRestore() || !context.mounted) {
          return;
        }
        await (redo ? history.redo() : history.undo());
        if (context.mounted) {
          await onRestored();
        }
      } catch (error, stack) {
        _log.error(
          'Canvas history restore failed',
          error: error,
          stackTrace: stack,
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                context.t(
                  error is CanvasHistoryConflict
                      ? LocaleKeys.productionHistoryConflict
                      : LocaleKeys.productionHistoryFailed,
                ),
              ),
            ),
          );
        }
      } finally {
        busy.value = false;
      }
    }

    return Actions(
      actions: {
        ProductionUndoIntent: CallbackAction<ProductionUndoIntent>(
          onInvoke: (_) => restore(false),
        ),
        ProductionRedoIntent: CallbackAction<ProductionRedoIntent>(
          onInvoke: (_) => restore(true),
        ),
      },
      child: Focus(
        autofocus: true,
        onKeyEvent: (_, event) {
          final focused = FocusManager.instance.primaryFocus?.context;
          if (focused?.widget is EditableText ||
              focused?.findAncestorWidgetOfExactType<EditableText>() != null) {
            return KeyEventResult.ignored;
          }
          final keyboard = HardwareKeyboard.instance;
          if (event is! KeyDownEvent ||
              keyboard.isAltPressed ||
              !(keyboard.isMetaPressed || keyboard.isControlPressed)) {
            return KeyEventResult.ignored;
          }
          if (event.logicalKey == LogicalKeyboardKey.keyZ) {
            restore(keyboard.isShiftPressed);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.keyY &&
              keyboard.isControlPressed) {
            restore(true);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: child,
      ),
    );
  }
}
