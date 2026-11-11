// 职责: 在制作画布内展示和编辑文本节点，空节点给出手写入口；离开编辑时自动保存，一次保存对应一步撤销。
// 关联文件:
//   lib/desktop/features/production/node_title.dart
//   lib/desktop/features/production/text_composer.dart
//   lib/desktop/features/production/node_card.dart
//   lib/desktop/features/production/history_region.dart
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/widgets/md/reveric_markdown_editor.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/text-input-ime.md
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/logger/app_logger.dart';
import '../../../shared/models/ai_provider.dart';
import '../../../shared/services/production/canvas_service.dart';
import '../../../shared/theme/canvas_colors.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/md/reveric_markdown_editor.dart';
import 'history_region.dart';
import 'node_title.dart';

final _log = AppLogger.forModule('ProductionText');

/// 文本节点输入框的发送；带 [model] 时用它新开一个对话，[effort] 是该模型的思考档位。
typedef ProductionTextSend =
    void Function(String prompt, {AiModelOption? model, String? effort});

/// 把文本节点输入框里的要求发给所在页面的聊天浮层并直接发送；没有聊天入口的视图不提供，节点只留手写。
class ProductionTextAsk extends InheritedWidget {
  const ProductionTextAsk({super.key, required this.ask, required super.child});
  final ProductionTextSend? ask;
  static ProductionTextSend? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ProductionTextAsk>()?.ask;
  @override
  bool updateShouldNotify(ProductionTextAsk oldWidget) =>
      (ask == null) != (oldWidget.ask == null);
}

class ProductionTextNode extends HookWidget {
  const ProductionTextNode({
    super.key,
    required this.service,
    required this.node,
    required this.selected,
    this.title,
  });
  final ProductionCanvasService service;
  final CanvasNode node;
  final bool selected;

  /// 卡片外的标题输入；没有画布浮层的宿主不提供，编辑时标题保持不变。
  final ProductionNodeTitle? title;

  @override
  Widget build(BuildContext context) {
    // 编辑期间保留进入时的基线，不让后台节点刷新覆盖尚未保存的输入。
    final editing = useState<CanvasNode?>(null);
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    if (editing.value case final initial?) {
      return _Editor(
        service: service,
        initial: initial,
        selected: selected,
        title: title,
        onClose: () {
          editing.value = null;
          title?.end(initial.id);
        },
      );
    }
    void edit({bool fromTitle = false}) {
      editing.value = node;
      title?.begin(node.id, node.title, fromTitle: fromTitle);
    }

    final start = useRef(edit)..value = edit;
    useEffect(() {
      final host = title;
      if (host == null) {
        return null;
      }
      void starter() => start.value(fromTitle: true);
      host.starters[node.id] = starter;
      return () {
        if (host.starters[node.id] == starter) {
          host.starters.remove(node.id);
        }
      };
    }, [title, node.id]);

    if (node.content.trim().isEmpty) {
      // 双击空白处进入编辑；起点行叠在上层单独接收点击，不用等双击判定超时。
      return Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: edit,
            ),
          ),
          SingleChildScrollView(
            padding: const EdgeInsets.all(RevericSpacing.x2l),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.t(LocaleKeys.productionAddTextHint),
                  style: typo.uiSmall.copyWith(color: colors.textMuted),
                ),
                const SizedBox(height: RevericSpacing.md),
                _TryRow(
                  icon: RevericIcons.edit_note_outlined,
                  label: context.t(LocaleKeys.productionTextTryWrite),
                  onTap: edit,
                ),
              ],
            ),
          ),
        ],
      );
    }
    // 双击正文或点卡片外的标题进入编辑；留白与编辑器一致，进出编辑时正文不跳动。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: edit,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(RevericSpacing.x3l),
        // 画布上拖动和双击优先，正文不做文本选择；要复制进编辑态或用「查看」。
        child: RevericMarkdownPreview(
          data: node.content,
          style: typo.bodySmall.copyWith(color: colors.textPrimary),
          selectable: false,
        ),
      ),
    );
  }
}

/// 空文本节点里的手写入口：图标 + 文案，悬停只换底色。
class _TryRow extends StatelessWidget {
  const _TryRow({required this.icon, required this.label, required this.onTap});
  final String icon, label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(RevericRadius.iconButton),
      hoverColor: canvasGlassHover(colors),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: RevericSpacing.xs,
          vertical: RevericSpacing.xs,
        ),
        child: Row(
          children: [
            RevericIcon(icon, size: 16, color: colors.textSecondary),
            const SizedBox(width: RevericSpacing.sm),
            Expanded(
              child: Text(
                label,
                style: typo.uiSmall.copyWith(color: colors.textPrimary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Editor extends HookWidget {
  const _Editor({
    required this.service,
    required this.initial,
    required this.selected,
    required this.title,
    required this.onClose,
  });
  final ProductionCanvasService service;
  final CanvasNode initial;
  final bool selected;

  final ProductionNodeTitle? title;
  final VoidCallback onClose;
  @override
  Widget build(BuildContext context) {
    // 外部 controller 是输入期的唯一真源，离开编辑时一次性写入。
    final content = useTextEditingController(text: initial.content);
    final contentFocus = useFocusNode();
    useEffect(() {
      if (title?.fromTitle != true) {
        contentFocus.requestFocus();
      }
      return null;
    }, const []);
    final writing = useRef<Future<bool>?>(null);
    final busy = useState(false);
    final close = useRef(onClose)..value = onClose;
    final owner = useMemoized(Object.new);
    final scope = ProductionHistoryScope.maybeOf(context);
    final typo = RevericTheme.typographyOf(context);
    final inside = useRef(false);
    Future<bool> persist() async {
      final name = title?.controller.text ?? initial.title;
      if (name == initial.title && content.text == initial.content) {
        close.value();
        return true;
      }
      busy.value = true;
      try {
        await service.updateText(
          initial.id,
          title: name,
          content: content.text,
          history: scope?.history,
        );
        if (context.mounted) {
          close.value();
        }
        return true;
      } catch (error, stack) {
        _log.error(
          'Text node save failed id=${initial.id}',
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

    useEffect(() {
      scope?.session?.guards[owner] = save;
      return () => scope?.session?.guards.remove(owner);
    }, [scope?.session, scope?.history, owner, service]);
    // 没有保存按钮：取消选中、焦点同时离开标题和正文，或按 Esc，都保存并退出编辑。
    useEffect(() {
      if (!selected) {
        save();
      }
      return null;
    }, [selected]);
    void blurred() {
      if (!inside.value && title?.focus.hasFocus != true) {
        save();
      }
    }

    final latest = useRef(blurred)..value = blurred;
    useEffect(() {
      final host = title;
      if (host == null) {
        return null;
      }
      void changed() => latest.value();
      void submit() => contentFocus.requestFocus();
      void done() => save();
      host.focus.addListener(changed);
      host
        ..onSubmit = submit
        ..onDone = done;
      return () {
        host.focus.removeListener(changed);
        if (host.onSubmit == submit) {
          host
            ..onSubmit = null
            ..onDone = null;
        }
      };
    }, [title]);
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): save},
      child: Focus(
        skipTraversal: true,
        canRequestFocus: false,
        onFocusChange: (focused) {
          inside.value = focused;
          blurred();
        },
        // 卡片本身就是输入框外观；编辑器自带四周留白，不再套边框。
        child: RevericMarkdownEditor(
          controller: content,
          focusNode: contentFocus,
          hintText: context.t(LocaleKeys.commonContent),
          disabled: busy.value,
          fontFamily: typo.bodySmall.fontFamily,
          fontSize: typo.bodySmall.fontSize?.round(),
          lineHeight: typo.bodySmall.height,
          showToolbar: false,
          borderless: true,
        ),
      ),
    );
  }
}
