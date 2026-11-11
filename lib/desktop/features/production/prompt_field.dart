// 职责: 展示可点击引用标签并保护复制粘贴时的资源身份。
// 关联文件:
//   lib/shared/services/production/canvas_service.dart
//   lib/desktop/features/production/region.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/theme/theme.dart';
import 'prompt_controller.dart';
import '../../../shared/models/storyboard/prompt.dart';
import '../../../shared/components/reveric_button.dart';

/// 在提示词末尾追加一个镜头模板，光标移到末尾。
void insertProductionShot(ProductionPromptController controller) {
  controller.text = controller.encode(
    StoryboardPrompt.appendShot(controller.source),
  );
  controller.selection = TextSelection.collapsed(
    offset: controller.text.length,
  );
}

class ProductionPromptField extends StatelessWidget {
  const ProductionPromptField({
    super.key,
    required this.controller,
    required this.onReference,
    this.maxLines = 6,
    this.actions = const [],
    this.footer = true,
    this.contentPadding,
    this.hintText,
    this.autofocus = false,
  });
  final ProductionPromptController controller;
  final VoidCallback onReference;

  /// 片段列表传 null 让提示词完整展开；画布浮层保持限高。
  final int? maxLines;

  /// 与「插入镜头」同一行、靠右的操作（如片段列表里的保存）。
  final List<Widget> actions;

  /// 是否显示「插入镜头」那一行；画布输入框把它放进自己的底栏。
  final bool footer;

  /// 输入区内边距；不给时用全局输入框主题。片段列表传零水平边距，让正文和标题对齐。
  final EdgeInsetsGeometry? contentPadding;
  final String? hintText;
  final bool autofocus;
  @override
  Widget build(BuildContext context) {
    Future<void> copy({bool cut = false}) async {
      final selected = controller.selection;
      if (!selected.isValid) {
        return;
      }
      await Clipboard.setData(
        ClipboardData(
          text: controller.decode(selected.textInside(controller.text)),
        ),
      );
      if (cut && context.mounted) {
        controller.value = TextEditingValue(
          text: controller.text.replaceRange(selected.start, selected.end, ''),
          selection: TextSelection.collapsed(offset: selected.start),
        );
      }
    }

    Future<void> paste() async {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!context.mounted || data?.text == null) {
        return;
      }
      final selected = controller.selection;
      final start = selected.isValid ? selected.start : controller.text.length;
      final end = selected.isValid ? selected.end : start;
      final String encoded;
      try {
        encoded = controller.encode(data!.text!);
      } on FormatException {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.t(LocaleKeys.storyboardInvalidPrompt)),
          ),
        );
        return;
      }
      controller.value = TextEditingValue(
        text: controller.text.replaceRange(start, end, encoded),
        selection: TextSelection.collapsed(offset: start + encoded.length),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CallbackShortcuts(
          bindings: {
            for (final modifier in [false, true]) ...{
              SingleActivator(
                LogicalKeyboardKey.keyC,
                control: !modifier,
                meta: modifier,
              ): () {
                copy();
              },
              SingleActivator(
                LogicalKeyboardKey.keyX,
                control: !modifier,
                meta: modifier,
              ): () {
                copy(cut: true);
              },
              SingleActivator(
                LogicalKeyboardKey.keyV,
                control: !modifier,
                meta: modifier,
              ): () {
                paste();
              },
            },
          },
          child: TextField(
            // Inline media spans and protocol-aware clipboard need the native editor surface.
            controller: controller,
            autofocus: autofocus,
            minLines: maxLines == null ? 1 : 3,
            maxLines: maxLines,
            style: RevericTheme.typographyOf(
              context,
            ).bodySmall.copyWith(height: footer ? null : 1.75),
            decoration: InputDecoration(
              border: InputBorder.none,
              contentPadding: contentPadding,
              hintText: hintText ?? context.t(LocaleKeys.productionPrompt),
            ),
            onChanged: (text) {
              final cursor = controller.selection.baseOffset;
              if (controller.value.composing.isCollapsed &&
                  cursor > 0 &&
                  text[cursor - 1] == '@') {
                onReference();
              }
            },
            contextMenuBuilder: (ctx, state) =>
                AdaptiveTextSelectionToolbar.buttonItems(
                  anchors: state.contextMenuAnchors,
                  buttonItems: [
                    ContextMenuButtonItem(
                      label: context.t(LocaleKeys.commonCopy),
                      onPressed: () {
                        copy();
                        state.hideToolbar();
                      },
                    ),
                    ContextMenuButtonItem(
                      label: context.t(LocaleKeys.commonCut),
                      onPressed: () {
                        copy(cut: true);
                        state.hideToolbar();
                      },
                    ),
                    ContextMenuButtonItem(
                      label: context.t(LocaleKeys.commonPaste),
                      onPressed: () {
                        paste();
                        state.hideToolbar();
                      },
                    ),
                  ],
                ),
          ),
        ),
        if (footer)
          Row(
            children: [
              RevericButton.text(
                label: context.t(LocaleKeys.productionInsertShot),
                onPressed: () => insertProductionShot(controller),
              ),
              const Spacer(),
              ...actions,
            ],
          ),
      ],
    );
  }
}
