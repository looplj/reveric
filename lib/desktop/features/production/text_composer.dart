// 职责: 选中文本节点时在其下方收集交给 AI 的写作要求，发送后才打开聊天并提交。
// 关联文件:
//   lib/desktop/features/production/text_node.dart
//   lib/desktop/features/production/region.dart
//   lib/desktop/features/production/popover.dart
//   lib/desktop/features/production/composer_toolbar.dart
//   lib/desktop/widgets/ai/model/mode_model_selector.dart
//   lib/shared/hooks/use_ai_mode_model_selection.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/hooks/use_ai_mode_model_selection.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/ai_provider.dart';
import '../../../shared/theme/theme.dart';
import '../../widgets/ai/model/mode_model_selector.dart';
import '../canvas/widgets/glass.dart';
import 'composer_toolbar.dart';
import 'popover.dart';
import 'text_node.dart';

class ProductionTextComposer extends HookConsumerWidget {
  const ProductionTextComposer({
    super.key,
    required this.node,
    required this.onSend,
  });
  final CanvasNode node;

  /// 把完整提示词交给聊天，用选中的模型新开对话并直接发送。
  final ProductionTextSend onSend;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final models = useAiModeModelSelection(ref);
    final prompt = useTextEditingController();
    final focus = useFocusNode();
    final empty = useListenableSelector(
      prompt,
      () => prompt.text.trim().isEmpty,
    );
    final typo = RevericTheme.typographyOf(context);
    // 起点只填进输入框，用户补完梗概再发送。
    void start(String text) {
      prompt.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      focus.requestFocus();
    }

    void send() {
      final task = prompt.text.trim();
      if (task.isEmpty) {
        return;
      }
      final model = models.runnable();
      // 提示词按节点 id 指给 agent，由它读写节点内容。
      onSend(
        '请针对画布上 id 为 ${node.id} 的文本节点'
        '${node.title.isEmpty ? '' : '「${node.title}」'}'
        '完成下面的要求，并把写好的内容保存到这个节点：\n$task',
        model: model,
        effort: reasoningEffortForOption(model, models.selectedEffort),
      );
      prompt.clear();
    }

    return Material(
      type: MaterialType.transparency,
      child: CanvasGlass(
        raised: true,
        radius: RevericRadius.canvasNode,
        padding: const EdgeInsets.fromLTRB(
          RevericSpacing.lg,
          RevericSpacing.lg,
          RevericSpacing.lg,
          RevericSpacing.md,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: RevericSpacing.xs,
              runSpacing: RevericSpacing.xs,
              children: [
                ProductionToolChip(
                  icon: RevericIcons.movie_outlined,
                  label: context.t(LocaleKeys.productionTextTryStoryboard),
                  onTap: () => start('写一份分镜脚本。故事梗概是：'),
                ),
                ProductionToolChip(
                  icon: RevericIcons.people,
                  label: context.t(LocaleKeys.productionTextTrySetting),
                  onTap: () => start('写一份角色与场景设定。故事梗概是：'),
                ),
                ProductionToolChip(
                  icon: RevericIcons.auto_fix_high_outlined,
                  label: context.t(LocaleKeys.productionTextTryPolish),
                  onTap: () => start('在保留原意的前提下扩写润色现有内容。'),
                ),
              ],
            ),
            const SizedBox(height: RevericSpacing.sm),
            // 画布留给输入框的高度不够时，提示词区先收缩，在框内滚动。
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: 60,
                  maxHeight: 140,
                ),
                child: SingleChildScrollView(
                  child: TextField(
                    controller: prompt,
                    focusNode: focus,
                    minLines: 3,
                    maxLines: null,
                    style: typo.bodySmall.copyWith(height: 1.75),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      hintText: context.t(LocaleKeys.productionTextAskHint),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: RevericSpacing.sm),
            ProductionComposerToolbar(
              submit: ProductionSendButton(
                icon: RevericIcons.arrow_upward_rounded,
                tooltip: context.t(LocaleKeys.commonSend),
                onPressed: empty ? null : send,
              ),
              children: [AiModeModelSelector(models: models)],
            ),
          ],
        ),
      ),
    );
  }
}
