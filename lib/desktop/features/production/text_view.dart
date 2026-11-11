// 职责: 在弹窗里放大查看文本节点的正文，与图片、视频节点的「查看」对应。
// 关联文件:
//   lib/desktop/features/production/node_bar.dart
//   lib/desktop/features/production/text_node.dart
//   lib/shared/widgets/md/reveric_markdown_editor.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
import 'package:flutter/material.dart';
import '../../../shared/components/reveric_button.dart';
import '../../../shared/components/reveric_dialog.dart';
import '../../../shared/database/novel_content_database.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/widgets/md/reveric_markdown_editor.dart';

Future<void> showProductionTextView(BuildContext context, CanvasNode node) =>
    showRevericDialog<void>(
      context: context,
      builder: (context) {
        final colors = RevericTheme.colorsOf(context);
        final typo = RevericTheme.typographyOf(context);
        return RevericDialog.panel(
          width: RevericSizes.mediaPreviewMaxWidth,
          title: Text(
            node.title.trim().isEmpty
                ? context.t(LocaleKeys.productionText)
                : node.title,
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(
              maxHeight: RevericSizes.mediaPreviewMaxHeight,
            ),
            child: SingleChildScrollView(
              child: Align(
                alignment: Alignment.topLeft,
                // 弹窗里可以选中复制，画布卡片上不行。
                child: RevericMarkdownPreview(
                  data: node.content,
                  style: typo.body.copyWith(color: colors.textPrimary),
                  showCopyButton: true,
                ),
              ),
            ),
          ),
          actions: [
            RevericButton.text(
              label: context.t(LocaleKeys.commonClose),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        );
      },
    );
