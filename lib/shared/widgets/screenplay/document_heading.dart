// 职责: 展示正文场次头与情绪，并连接场次属性弹窗。
// 关联文件:
//   lib/shared/widgets/screenplay/scene_properties.dart
//   lib/shared/widgets/screenplay/document_rows.dart
//   lib/shared/models/screenplay_document.dart
//   lib/shared/widgets/screenplay/director_shell.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
//   assets/translations/en/director.json
//   assets/translations/zh-CN/director.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/hooks.md
//   .agents/rules/i18n.md

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'scene_properties.dart';
import 'emotion_badges.dart';
import 'labels.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/screenplay_element.dart';
import '../../theme/theme.dart';
import 'document_rows.dart';
import 'element_layout.dart';
import 'text_styles.dart';

class ScreenplayDocumentHeading extends HookWidget {
  const ScreenplayDocumentHeading({
    super.key,
    required this.actions,
    required this.element,
  });
  final ScreenplayDocumentActions actions;
  final ScreenplayElement element;
  @override
  Widget build(BuildContext context) {
    final c = actions.session.controller;
    final number = actions.session.sceneNumber(element.sceneId!);
    final styles = ScreenplayTextStyles.of(context);
    final location =
        c.locationNames[element.locationId] ??
        context.t(
          element.locationId == null
              ? LocaleKeys.screenplayUntitledScene
              : LocaleKeys.screenplayDeletedLocation,
        );
    final condition = screenplayInteriorExteriorLabel(
      context,
      element.interiorExterior,
    );
    final time = element.timeLabel ?? '';
    final emotion =
        c.screenplay!.scenes[element.sceneId]!.emotion ?? const <String>[];
    final cast = c.screenplay!.scenes[element.sceneId]!.cast
        .map(
          (id) =>
              c.characterNames[id] ??
              context.t(LocaleKeys.screenplayDeletedCharacter),
        )
        .toList();
    final heading = Text.rich(
      TextSpan(
        children: [
          TextSpan(text: '$number、', style: styles.sceneNumber),
          TextSpan(
            text: location,
            style:
                element.locationId != null &&
                    !c.locationNames.containsKey(element.locationId)
                ? styles.sceneHeading.copyWith(
                    color: RevericTheme.colorsOf(context).warningText,
                  )
                : null,
          ),
          if (time.isNotEmpty || condition.isNotEmpty) ...[
            const TextSpan(text: '  '),
            TextSpan(text: time),
            if (time.isNotEmpty && condition.isNotEmpty)
              TextSpan(text: ' / ', style: styles.sceneSeparator),
            TextSpan(text: condition),
          ],
        ],
      ),
      style: styles.sceneHeading,
    );
    Future<void> edit() => showSceneProperties(
      context,
      databasePath: actions.databasePath,
      novelId: actions.novelId,
      sceneId: element.sceneId!,
      episodeId: element.episodeId!,
      mobile: actions.mobile,
      session: actions.session,
    );

    actions.session.headingEditors[element.id!] = () => unawaited(edit());
    return Padding(
      padding: EdgeInsets.only(
        top: actions.session.indices[element.id] == 0 ? 0 : 40,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: edit,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Row(
                children: [
                  // 场次排序收在左栏场次列表里，正文只留与其它元素对齐的沟槽。
                  const SizedBox(width: ScreenplayElementLayout.gutter),
                  Expanded(
                    child: Tooltip(
                      message:
                          element.locationId != null &&
                              !c.locationNames.containsKey(element.locationId)
                          ? context.t(LocaleKeys.screenplayMissingReferenceHint)
                          : '',
                      child: heading,
                    ),
                  ),
                  if (emotion.isNotEmpty) ...[
                    const SizedBox(width: RevericSpacing.sm),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: actions.mobile ? 100 : 180,
                      ),
                      child: SelectionContainer.disabled(
                        child: SceneEmotionBadges(
                          emotion: emotion,
                          max: actions.mobile ? 1 : 2,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (cast.isNotEmpty) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(
                left: ScreenplayElementLayout.gutter,
              ),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: context.t(LocaleKeys.screenplayCastLine)),
                    TextSpan(text: cast.join('、'), style: styles.castNames),
                  ],
                ),
                style: styles.cast,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
