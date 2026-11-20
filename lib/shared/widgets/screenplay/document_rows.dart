// 职责: 按稳定节点身份呈现标题和正文，接线文档命令、局部输入与场次滚动定位。
// 关联文件:
//   lib/shared/components/reveric_button.dart
//   lib/shared/components/reveric_dialog.dart
//   lib/shared/widgets/screenplay/document_editor.dart
//   lib/shared/widgets/screenplay/document_session.dart
//   lib/shared/widgets/screenplay/document_heading.dart
//   lib/shared/widgets/screenplay/text_field.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/design-system.md
//   .agents/rules/performance.md

import '../../components/dialog_feedback.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import '../../localization/app_localization.dart';
import '../../localization/locale_keys.dart';
import '../../models/screenplay.dart';
import '../../models/screenplay_editing.dart';
import '../../models/screenplay_element.dart';
import '../../theme/theme.dart';
import 'document_editor.dart';
import 'document_heading.dart';
import 'document_session.dart';
import 'editing_row.dart';
import 'backspace_target.dart';
import 'element_layout.dart';
import 'text_field.dart';
import 'text_styles.dart';
import '../../components/reveric_dialog.dart';
import '../../components/reveric_button.dart';

class ScreenplayDocumentActions {
  ScreenplayDocumentActions(
    this.session,
    this.pickCharacter,
    this.mobile,
    this.databasePath,
    this.novelId,
  );
  final ScreenplayDocumentSession session;
  final ScreenplayPickCharacter pickCharacter;
  final bool mobile;
  final String databasePath;
  final String novelId;

  void showError(BuildContext context, String key) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.t(key))));
  }

  Future<void> showSaveError(BuildContext context) async {
    final error = session.queue.lastError;
    final stale =
        error is ScreenplayServiceException &&
        error.errorCode == 'stale_screenplay_edit';
    await showRevericDialog<void>(
      context: context,
      builder: (_) => RevericDialog(
        title: context.t(
          stale
              ? LocaleKeys.screenplayStaleEdit
              : LocaleKeys.screenplaySaveFailed,
        ),
        content: DialogFeedback.intrinsic(
          builder: (dialogContext) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(dialogContext.t(LocaleKeys.screenplayKeepDraft)),
              const SizedBox(height: RevericSpacing.x4l),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: RevericSpacing.sm,
                overflowSpacing: RevericSpacing.sm,
                children: [
                  RevericButton.secondary(
                    label: context.t(LocaleKeys.screenplayCopyDraft),
                    onPressed: () async {
                      session.controller.select(
                        TextSelection(
                          baseOffset: 0,
                          extentOffset: session.controller.source.length,
                        ),
                      );
                      await Clipboard.setData(
                        ClipboardData(text: session.controller.selectedText()),
                      );
                    },
                  ),
                  RevericButton.secondary(
                    label: context.t(LocaleKeys.screenplayReloadDraft),
                    onPressed: () async {
                      try {
                        await session.reload();
                        if (dialogContext.mounted) {
                          Navigator.of(dialogContext).pop();
                        }
                      } catch (_) {
                        if (dialogContext.mounted) {
                          ScaffoldMessenger.of(dialogContext).showSnackBar(
                            SnackBar(
                              showCloseIcon: true,
                              content: DialogToast(
                                variant: DialogToastVariant.error,
                                child: Text(
                                  dialogContext.t(
                                    LocaleKeys.screenplaySaveFailed,
                                  ),
                                ),
                              ),
                            ),
                          );
                        }
                      }
                    },
                  ),
                  if (!stale)
                    RevericButton.primary(
                      label: context.t(LocaleKeys.commonRetry),
                      onPressed: () {
                        Navigator.of(dialogContext).pop();
                        unawaited(session.flush().onError((_, _) {}));
                      },
                    ),
                  RevericButton.secondary(
                    label: context.t(LocaleKeys.commonCancel),
                    onPressed: () => Navigator.of(dialogContext).pop(),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> pick(BuildContext context, ScreenplayElementType? type) async {
    final controller = session.controller;
    if (controller.isComposing) {
      return;
    }
    try {
      if (type == null) {
        await controller.splitScene();
        return;
      }
      if (controller.value.isEmpty) {
        controller.editDocument(controller.screenplay!.createFirstScene());
      }
      var index = controller
          .positionAt(controller.selection.extentOffset)
          .index;
      if (controller.value[index].isHeading) {
        await controller.enter(soft: false);
        index = controller.positionAt(controller.selection.extentOffset).index;
      }
      if (!context.mounted) {
        return;
      }
      final current = controller.value[index];
      String? characterId = current.characterId;
      if (type == ScreenplayElementType.character) {
        final revision = controller.revision;
        characterId = await pickCharacter(context, current);
        if (characterId == null || controller.revision != revision) {
          return;
        }
      }
      if (!canChangeScreenplayElementType(controller.value, index, type)) {
        if (!context.mounted) {
          return;
        }
        if (type == ScreenplayElementType.dialogue ||
            type == ScreenplayElementType.parenthetical) {
          final revision = controller.revision;
          characterId = await pickCharacter(context, current);
          if (characterId == null || controller.revision != revision) {
            return;
          }
          final cue = ScreenplayElement(
            type: ScreenplayElementType.character,
            characterId: characterId,
            episodeId: current.episodeId,
            sceneId: current.sceneId,
          );
          controller.edit(
            [...controller.value]
              ..insert(index, cue)
              ..[index + 1] = changeScreenplayElementType(current, type),
          );
          controller.select(
            TextSelection.collapsed(offset: controller.startOf(index + 1)),
          );
        }
        return;
      }
      final updated = changeScreenplayElementType(
        current,
        type,
        characterId: characterId,
      );
      var nodes = [...controller.value]..[index] = updated;
      if (type == ScreenplayElementType.character) {
        final dialogue = prepareScreenplayDialogue(nodes, index);
        nodes = dialogue.elements;
        controller.edit(nodes);
        controller.select(
          TextSelection.collapsed(offset: controller.startOf(dialogue.index)),
        );
      } else {
        controller.edit(nodes);
      }
    } on ScreenplayServiceException catch (error) {
      if (context.mounted) {
        showError(
          context,
          error.errorCode == 'first_scene_heading_required'
              ? LocaleKeys.screenplayFirstHeadingRequired
              : LocaleKeys.screenplaySaveFailed,
        );
      }
    }
  }

  void cycleType(BuildContext context, bool backward) {
    final c = session.controller;
    if (c.value.isEmpty) {
      return;
    }
    final type = c.value[c.positionAt(c.selection.extentOffset).index].type;
    final index = screenplayBodyElementTypes.indexOf(type);
    unawaited(
      pick(
        context,
        screenplayBodyElementTypes[(index + (backward ? -1 : 1)) %
            screenplayBodyElementTypes.length],
      ),
    );
  }

  void update(String id, String text) {
    final c = session.controller;
    final index = session.indices[id];
    if (index == null) {
      return;
    }
    final next = c.value[index].copyWith(text: text);
    c.edit([...c.value]..[index] = next);
  }
}

class ScreenplayDocumentRows extends HookWidget {
  const ScreenplayDocumentRows({
    super.key,
    required this.actions,
    required this.selectedSceneId,
    this.onVisibleSceneChanged,
  });
  final ScreenplayDocumentActions actions;

  /// 当前场次。用 listenable 传是因为它只驱动滚动定位、不参与渲染；
  /// 走普通参数会让整棵正文跟着高亮变化重建，滚动跟随时每跨一场卡一次。
  final ValueListenable<String?> selectedSceneId;

  /// 滚动到新场次时上报视口顶部那一场；宿主不需要反向联动时传 null。
  /// 必须是稳定回调，否则每次宿主 build 都会重建正文。
  final ValueChanged<String>? onVisibleSceneChanged;

  @override
  Widget build(BuildContext context) {
    final scroll = useScrollController();
    final headingKeys = useMemoized(() => <String, GlobalKey>{}, [
      actions.session,
    ]);
    final lastReported = useRef<String?>(null);
    // 只抑制紧跟上报的那一次回拉。若改成「这个 id 报过就永不回拉」，正文一旦
    // 因为外部改动偏离该场，就再没有东西能把它拉回来，高亮会永久脱节。
    final suppressReveal = useRef<String?>(null);

    useEffect(() {
      void revealSelected() {
        final sceneId = selectedSceneId.value;
        final suppressed = suppressReveal.value;
        suppressReveal.value = null;
        if (sceneId != null && sceneId == suppressed) {
          return;
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final heading = actions.session.controller.value
              .where((e) => e.isHeading && e.sceneId == sceneId)
              .firstOrNull;
          final target = headingKeys[heading?.id]?.currentContext;
          if (target != null) {
            Scrollable.ensureVisible(target, alignment: 0.1);
          }
        });
      }

      selectedSceneId.addListener(revealSelected);
      revealSelected();
      return () => selectedSceneId.removeListener(revealSelected);
    }, [selectedSceneId, headingKeys]);

    final report = onVisibleSceneChanged;
    useEffect(() {
      if (report == null) {
        return null;
      }
      Timer? settle;
      void onScroll() {
        settle?.cancel();
        // 滚动过程中不写状态：每跨一场就落一次盘会把滚动拖成逐帧写库。
        settle = Timer(const Duration(milliseconds: 120), () {
          final sceneId = _sceneAtViewportTop(scroll, headingKeys, actions);
          if (sceneId == null || sceneId == lastReported.value) {
            return;
          }
          lastReported.value = sceneId;
          suppressReveal.value = sceneId;
          report(sceneId);
        });
      }

      scroll.addListener(onScroll);
      return () {
        settle?.cancel();
        scroll.removeListener(onScroll);
      };
    }, [scroll, report, headingKeys]);

    return SingleChildScrollView(
      controller: scroll,
      padding: actions.mobile
          ? const EdgeInsets.all(RevericSpacing.lg)
          : const EdgeInsets.fromLTRB(
              RevericSpacing.editorPaddingH - ScreenplayElementLayout.gutter,
              40,
              RevericSpacing.editorPaddingH,
              120,
            ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: RevericSizes.screenplayPageMaxWidth,
          ),
          child: ValueListenableBuilder<List<String>>(
            valueListenable: actions.session.structure,
            builder: (context, ids, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (ids.isEmpty)
                  TextButton(
                    onPressed: () => actions.session.controller.editDocument(
                      actions.session.controller.screenplay!.createFirstScene(),
                    ),
                    child: Text(context.t(LocaleKeys.screenplayStartWriting)),
                  ),
                for (final id in ids)
                  _DocumentNode(
                    key: ValueKey(id),
                    actions: actions,
                    id: id,
                    headingKey: headingKeys.putIfAbsent(id, GlobalKey.new),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 视口顶部所在场次：按文档顺序取最后一个标题已滚过顶沿的场次。
///
/// 留一点余量，标题刚滚出上沿时这一场仍算「正在读」，否则跨场那一瞬会闪回上一场。
/// 滚到顶部时没有任何标题越过顶沿，这时正在读的是第一场 —— 不能返回 null，
/// 否则往上滚到头这一步不上报，当前场次会卡在下滚时留下的旧值。
String? _sceneAtViewportTop(
  ScrollController scroll,
  Map<String, GlobalKey> headingKeys,
  ScreenplayDocumentActions actions,
) {
  if (!scroll.hasClients) {
    return null;
  }
  const slack = 24.0;
  final pixels = scroll.position.pixels;
  String? current;
  String? first;
  for (final element in actions.session.controller.value) {
    if (!element.isHeading) {
      continue;
    }
    final context = headingKeys[element.id]?.currentContext;
    if (context == null) {
      continue;
    }
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) {
      continue;
    }
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) {
      continue;
    }
    first ??= element.sceneId;
    if (viewport.getOffsetToReveal(box, 0).offset > pixels + slack) {
      break;
    }
    current = element.sceneId;
  }
  return current ?? first;
}

class _DocumentNode extends HookWidget {
  const _DocumentNode({
    super.key,
    required this.actions,
    required this.id,
    required this.headingKey,
  });
  final ScreenplayDocumentActions actions;
  final String id;
  final GlobalKey headingKey;
  @override
  Widget build(BuildContext context) {
    final controller = actions.session.controller;
    final isCaret = useListenableSelector(controller.document, () {
      if (actions.session.nodes[id]!.value.isHeading ||
          !controller.selection.isValid ||
          controller.value.isEmpty) {
        return false;
      }
      return controller.positionAt(controller.selection.extentOffset).index ==
          actions.session.indices[id];
    });
    // 没有正文的场次在标题下留一块可点的正文区：标题本身点了是开属性弹窗，
    // 不留这块的话光标无处可落，这一场就再也写不进内容。
    final isEmptyScene = useListenableSelector(actions.session.structure, () {
      final ids = actions.session.structure.value;
      final at = actions.session.indices[id];
      if (at == null || !actions.session.nodes[id]!.value.isHeading) {
        return false;
      }
      return at + 1 >= ids.length ||
          actions.session.nodes[ids[at + 1]]!.value.isHeading;
    });
    return ValueListenableBuilder<ScreenplayElement>(
      valueListenable: actions.session.nodes[id]!,
      builder: (context, element, _) {
        final index = actions.session.indices[id]!;
        final styles = ScreenplayTextStyles.of(context);
        final c = actions.session.controller;
        if (element.isHeading) {
          final heading = ScreenplayEditingRow(
            index: index,
            child: ScreenplayDocumentHeading(
              key: headingKey,
              actions: actions,
              element: element,
            ),
          );
          if (!isEmptyScene) {
            return heading;
          }
          final lineHeight =
              (styles.action.fontSize ?? 16) * (styles.action.height ?? 1.5);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              heading,
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (c.isComposing) {
                    return;
                  }
                  c.select(
                    TextSelection.collapsed(offset: c.startOf(index)),
                    requestFocus: false,
                  );
                  unawaited(c.enter(soft: false));
                },
                child: MouseRegion(
                  cursor: SystemMouseCursors.text,
                  child: SizedBox(
                    height:
                        screenplayElementTopSpacing(
                          ScreenplayElementType.action,
                        ) +
                        lineHeight,
                  ),
                ),
              ),
            ],
          );
        }
        if (element.type == ScreenplayElementType.character) {
          return ScreenplayEditingRow(
            index: index,
            child: ScreenplayElementLayout(
              type: element.type,
              isCaret: isCaret,
              topSpacing: screenplayElementTopSpacing(element.type),
              child: ScreenplayBackspaceTarget(
                onBackspace: () => unawaited(
                  c.replaceRange(c.startOf(index), c.startOf(index) + 1, ''),
                ),
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () async {
                    c.select(
                      TextSelection.collapsed(offset: c.startOf(index)),
                      requestFocus: false,
                    );
                    await actions.pick(
                      context,
                      ScreenplayElementType.character,
                    );
                  },
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text:
                              c.characterNames[element.characterId] ??
                              context.t(LocaleKeys.screenplayDeletedCharacter),
                          style:
                              c.characterNames.containsKey(element.characterId)
                              ? null
                              : styles.character.copyWith(
                                  color: RevericTheme.colorsOf(
                                    context,
                                  ).warningText,
                                ),
                        ),
                        if (element.extension.isNotEmpty)
                          TextSpan(
                            text: '（${element.extension}）',
                            style: styles.characterExtension,
                          ),
                        const TextSpan(text: '：'),
                      ],
                    ),
                    style: styles.character,
                  ),
                ),
              ),
            ),
          );
        }
        final style = switch (element.type) {
          ScreenplayElementType.dialogue => styles.dialogue,
          ScreenplayElementType.parenthetical => styles.parenthetical,
          ScreenplayElementType.transition => styles.transition,
          ScreenplayElementType.subtitle => styles.subtitle,
          ScreenplayElementType.note => styles.note,
          _ => styles.action,
        };
        final field = ScreenplayElementField(
          text: element.text,
          style: style,
          textAlign: element.type == ScreenplayElementType.transition
              ? TextAlign.right
              : TextAlign.left,
          onChanged: (text) => actions.update(id, text),
          onFocused: () {},
          onEnter: (_) => unawaited(c.enter(soft: false)),
          onTab: (backward) => actions.cycleType(context, backward),
          prefix: element.type == ScreenplayElementType.parenthetical
              ? '（'
              : element.type == ScreenplayElementType.note
              ? '${context.t(LocaleKeys.screenplayNotePrefix)} '
              : '',
          suffix: element.type == ScreenplayElementType.parenthetical
              ? '）'
              : '',
        );
        return ScreenplayEditingRow(
          index: index,
          child: ScreenplayElementLayout(
            type: element.type,
            isCaret: isCaret,
            topSpacing: screenplayElementTopSpacing(element.type),
            child:
                element.type == ScreenplayElementType.subtitle &&
                    !actions.mobile
                ? Padding(
                    padding: const EdgeInsets.only(bottom: 18),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 352),
                        child: field,
                      ),
                    ),
                  )
                : field,
          ),
        );
      },
    );
  }
}
