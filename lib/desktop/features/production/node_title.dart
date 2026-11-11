// 职责: 在节点卡片外的标题原位改名：持有标题输入状态，并提供叠在标题上的点击区与输入框。
// 关联文件:
//   lib/desktop/features/production/board.dart
//   lib/desktop/features/production/node_card.dart
//   lib/desktop/features/production/text_node.dart
//   lib/desktop/features/production/grid/group_titles.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/text-input-ime.md
//   .agents/rules/design-system.md
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/theme/theme.dart';

/// 导演文档标题的上限，其他节点沿用同一长度。
const _maxLength = 80;

/// 卡片外标题的输入状态，由画布持有。
/// 标题在节点矩形之外，画布内部会把那里的点击当成点空白，输入框只能放在画布之上的浮层里；
/// 文本节点卡片里的正文编辑器与它共用这一份状态。
class ProductionNodeTitle {
  final controller = TextEditingController();
  final focus = FocusNode();

  /// 正在改标题的节点 id。
  final editing = ValueNotifier<String?>(null);

  /// 进入编辑时的标题，没改就不写库。
  String initial = '';

  /// 文本节点登记：标题里回车回到正文、Esc 结束编辑。
  VoidCallback? onSubmit, onDone;

  /// 非编辑态点标题时进入编辑，按节点 id 登记。
  final starters = <String, VoidCallback>{};

  /// 这次编辑从标题开始，进入后焦点落在标题而不是正文。
  bool fromTitle = false;
  void begin(String nodeId, String text, {required bool fromTitle}) {
    initial = text;
    controller.text = text;
    this.fromTitle = fromTitle;
    editing.value = nodeId;
  }

  void end(String nodeId) {
    if (editing.value == nodeId) {
      editing.value = null;
    }
  }

  void dispose() {
    controller.dispose();
    focus.dispose();
    editing.dispose();
  }
}

/// 卡片标题里类型图标的宽度加间距；输入框从名字的位置开始，图标仍由卡片画。
const _nameInset = 12 + RevericSpacing.xxs;

/// 叠在卡片外标题原位：编辑态是同样式的输入框，非编辑态是透明的点击区，点了进入编辑。
class ProductionNodeTitleField extends HookWidget {
  const ProductionNodeTitleField({
    super.key,
    required this.title,
    required this.nodeId,
    this.load,
    this.commit,
  });
  final ProductionNodeTitle title;
  final String nodeId;

  /// 读当前标题；返回 null 表示这个节点的标题不可改。
  /// 文本节点不传：标题随卡片里的正文一起进入编辑、一起保存。
  final Future<String?> Function()? load;

  /// 写入新标题；与 [load] 成对提供。
  final Future<void> Function(String text)? commit;
  @override
  Widget build(BuildContext context) {
    final editing = useValueListenable(title.editing) == nodeId;
    final latest = useRef(this)..value = this;
    final finishing = useRef(false);
    // 卸载时也可能要保存（换了选中节点）；那时已不能再向上查找，提前取好。
    final notice =
        useRef((
            ScaffoldMessenger.maybeOf(context),
            context.t(LocaleKeys.commonSaveFailed),
          ))
          ..value = (
            ScaffoldMessenger.maybeOf(context),
            context.t(LocaleKeys.commonSaveFailed),
          );
    Future<void> finish() async {
      final write = latest.value.commit;
      if (write == null || finishing.value || title.editing.value != nodeId) {
        return;
      }
      finishing.value = true;
      final text = title.controller.text.trim();
      try {
        if (text != title.initial.trim()) {
          await write(text);
        }
      } catch (_) {
        // 服务层记录数据库异常和 stack trace。
        notice.value.$1?.showSnackBar(SnackBar(content: Text(notice.value.$2)));
      } finally {
        finishing.value = false;
        title.end(nodeId);
      }
    }

    // 只改标题的节点：登记进入编辑的入口；焦点离开或换了选中节点时保存。
    useEffect(() {
      if (load == null) {
        return null;
      }
      Future<void> start() async {
        final text = await latest.value.load?.call();
        if (text != null && context.mounted && title.editing.value == null) {
          title.begin(nodeId, text, fromTitle: true);
        }
      }

      void starter() => unawaited(start());
      void blurred() {
        if (!title.focus.hasFocus) {
          unawaited(finish());
        }
      }

      title.starters[nodeId] = starter;
      title.focus.addListener(blurred);
      return () {
        title.focus.removeListener(blurred);
        if (title.starters[nodeId] == starter) {
          title.starters.remove(nodeId);
        }
        unawaited(finish());
      };
    }, [nodeId, load == null]);
    // 从标题进入编辑时焦点落在标题；等输入框建出来再要焦点。
    useEffect(() {
      if (editing && title.fromTitle) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (title.editing.value == nodeId) {
            title.focus.requestFocus();
          }
        });
      }
      return null;
    }, [editing]);
    if (!editing) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => title.starters[nodeId]?.call(),
      );
    }
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    return Material(
      type: MaterialType.transparency,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              commit == null ? title.onDone?.call() : unawaited(finish()),
        },
        child: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: _nameInset),
            child: TextField(
              controller: title.controller,
              focusNode: title.focus,
              maxLines: 1,
              inputFormatters: [LengthLimitingTextInputFormatter(_maxLength)],
              style: typo.uiSmall.copyWith(color: colors.textPrimary),
              onSubmitted: (_) =>
                  commit == null ? title.onSubmit?.call() : unawaited(finish()),
              decoration: InputDecoration.collapsed(
                hintText: context.t(LocaleKeys.commonTitle),
                hintStyle: typo.uiSmall.copyWith(color: colors.textSubtle),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
