// 职责: 从桌面剧本或章节编辑器打开当前正文的朗读快照。
// 关联文件:
//   lib/desktop/features/screenplay/script.dart
//   lib/desktop/features/narration/dialog.dart
//   lib/shared/widgets/screenplay/document_session.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
// 遵循的 Rules:
//   .agents/rules/hooks.md

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../../shared/components/reveric_button.dart';
import '../../../shared/components/reveric_dialog.dart';
import '../../../shared/components/reveric_icon_button.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/models/narration.dart';
import '../../../shared/theme/theme.dart';
import '../../../shared/utils/text_input_composing.dart';
import '../../../shared/widgets/frame_safe_text_editing_value_builder.dart';
import '../../../shared/widgets/screenplay/document_session.dart';
import 'dialog.dart';

bool get supportsDesktopNarration =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS);

class NarrationButton extends HookWidget {
  const NarrationButton({
    super.key,
    required this.workId,
    required this.session,
    this.sceneId,
  });
  final String workId;
  final ScreenplayDocumentSession session;
  final String? sceneId;

  @override
  Widget build(BuildContext context) {
    final composing = useListenableSelector(
      session.controller,
      () => session.controller.isComposing,
    );
    if (!supportsDesktopNarration) {
      return const SizedBox.shrink();
    }
    return RevericButton.text(
      key: const ValueKey('screenplay-narration'),
      size: RevericButtonSize.compact,
      label: context.t(LocaleKeys.narrationTitle),
      icon: RevericIcons.play_arrow,
      onPressed: composing
          ? null
          : () {
              final controller = session.controller;
              if (sceneId != null &&
                  !controller.screenplay!.sceneOrder.contains(sceneId)) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(context.t(LocaleKeys.narrationMissingScene)),
                  ),
                );
                return;
              }
              final source = NarrationSource(
                document: controller.screenplay!,
                characterNames: controller.characterNames,
                locationNames: controller.locationNames,
                startSceneId: sceneId,
              );
              showRevericDialog<void>(
                context: context,
                builder: (_) => NarrationDialog(workId: workId, source: source),
              );
            },
    );
  }
}

class ChapterNarrationButton extends StatelessWidget {
  const ChapterNarrationButton({
    super.key,
    required this.workId,
    required this.controller,
    required this.isChapterReady,
  });

  final String workId;
  final TextEditingController controller;
  final bool isChapterReady;

  @override
  Widget build(BuildContext context) {
    return FrameSafeTextEditingValueBuilder(
      controller: controller,
      builder: (context, value, _) => RevericIconButton(
        icon: RevericIcons.play_arrow,
        tooltip: context.t(LocaleKeys.narrationTitle),
        onPressed:
            isChapterReady &&
                (!value.composing.isValid || value.composing.isCollapsed) &&
                value.text.trim().isNotEmpty
            ? () {
                final text = controller.text;
                if (!isTextInputComposing(controller) &&
                    text.trim().isNotEmpty) {
                  showNovelNarration(context, workId: workId, text: text);
                }
              }
            : null,
      ),
    );
  }
}
