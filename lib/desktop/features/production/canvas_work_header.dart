// 职责: 展示画布作品标题、返回操作与作品默认制作设置，独立提交标题编辑。
// 关联文件:
//   lib/desktop/features/production/canvas_work.dart
//   lib/desktop/features/production/history_region.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json
// 遵循的 Rules:
//   .agents/rules/hooks.md
//   .agents/rules/desktop-window-frame.md
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../../../shared/database/app_database.dart' show Novel;
import '../../../shared/components/reveric_icon_button.dart';
import '../../../shared/components/reveric_text_field.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/providers/novel_providers.dart';
import '../../../shared/services/novel_actions.dart';
import '../../../shared/theme/theme.dart';
import '../../widgets/desktop_window_frame.dart';
import 'history_region.dart';
import 'spec_panel.dart';
import 'style_button.dart';
import 'support.dart';

class CanvasWorkHeader extends HookConsumerWidget {
  const CanvasWorkHeader({
    super.key,
    required this.novel,
    required this.onBack,
    required this.registerFlush,
    required this.gestureKeys,
  });
  final ({
    GlobalKey back,
    GlobalKey title,
    GlobalKey save,
    GlobalKey cancel,
    GlobalKey settings,
  })
  gestureKeys;
  final Novel novel;
  final VoidCallback onBack;
  final ValueChanged<Future<void> Function()?> registerFlush;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editing = useState(false);
    final busy = useState(false);
    final title = useTextEditingController(text: novel.title);
    final focus = useFocusNode();
    final error = useState<String?>(null);
    final registered = useRef(registerFlush)..value = registerFlush;
    final service = ProductionHistoryScope.of(context).service;
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    Future<void> save() async {
      if (!editing.value) {
        return;
      }
      final next = title.text.trim();
      if (next.isEmpty) {
        error.value = context.t(LocaleKeys.commonRequired);
        throw StateError('Canvas title required');
      }
      busy.value = true;
      try {
        await ref
            .read(novelActionsProvider)
            .updateNovel(
              novel: novel,
              title: next,
              description: novel.description,
              removeCover: false,
            );
        if (context.mounted) {
          editing.value = false;
          error.value = null;
        }
      } on NovelTitleConflictException {
        if (context.mounted) {
          error.value = context.t(LocaleKeys.libraryDuplicateName);
        }
        rethrow;
      } finally {
        if (context.mounted) {
          busy.value = false;
        }
      }
    }

    void cancel() {
      editing.value = false;
      error.value = null;
    }

    void rename() {
      title.text = novel.title;
      editing.value = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          focus.requestFocus();
        }
      });
    }

    final saveRef = useRef(save)..value = save;
    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          registered.value(() => saveRef.value());
        }
      });
      return () => registered.value(null);
    }, const []);
    return SizedBox(
      height:
          DesktopWindowFrame.titleBarHeight +
          DesktopWindowFrame.captionSafeTopInset +
          RevericSpacing.sm,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: DesktopWindowFrame.sidebarLeadingInset),
          Expanded(
            child: SizedBox(
              height: DesktopWindowFrame.titleBarHeight,
              child: Row(
                children: [
                  RevericIconButton(
                    key: gestureKeys.back,
                    icon: RevericIcons.arrow_back,
                    tooltip: context.t(LocaleKeys.commonBack),
                    onPressed: busy.value ? null : onBack,
                  ),
                  const SizedBox(width: RevericSpacing.xs),
                  if (editing.value) ...[
                    // 宽度封顶，确认与取消紧跟输入框，不被推到窗口另一侧。
                    Flexible(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: RevericSizes.productionTitleFieldWidth,
                        ),
                        child: CallbackShortcuts(
                          bindings: {
                            const SingleActivator(LogicalKeyboardKey.escape):
                                cancel,
                          },
                          child: RevericTextField(
                            key: gestureKeys.title,
                            fieldKey: const ValueKey('canvas-work-title'),
                            controller: title,
                            focusNode: focus,
                            enabled: !busy.value,
                            onSubmitted: (_) => productionRun(context, save),
                          ),
                        ),
                      ),
                    ),
                    if (error.value != null)
                      Padding(
                        padding: const EdgeInsets.only(left: RevericSpacing.sm),
                        child: Tooltip(
                          message: error.value!,
                          child: RevericIcon(
                            RevericIcons.error_outline,
                            color: colors.error,
                          ),
                        ),
                      ),
                    RevericIconButton(
                      key: gestureKeys.save,
                      icon: RevericIcons.check,
                      tooltip: context.t(LocaleKeys.commonSave),
                      onPressed: busy.value
                          ? null
                          : () => productionRun(context, save),
                    ),
                    RevericIconButton(
                      key: gestureKeys.cancel,
                      icon: RevericIcons.close,
                      tooltip: context.t(LocaleKeys.commonCancel),
                      onPressed: cancel,
                    ),
                  ] else
                    // 标题本身就是重命名入口，铅笔贴着标题提示可编辑。
                    Flexible(
                      child: Tooltip(
                        message: context.t(LocaleKeys.commonRename),
                        child: InkWell(
                          key: gestureKeys.title,
                          borderRadius: BorderRadius.circular(
                            RevericRadius.iconButton,
                          ),
                          hoverColor: colors.hover,
                          onTap: busy.value ? null : rename,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: RevericSpacing.sm,
                              vertical: RevericSpacing.xs,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Text(
                                    novel.title,
                                    key: const ValueKey(
                                      'canvas-work-title-label',
                                    ),
                                    style: typo.uiSemibold.copyWith(
                                      color: colors.textPrimary,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: RevericSpacing.xs),
                                RevericIcon(
                                  RevericIcons.edit,
                                  size: 14,
                                  color: colors.textSubtle,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            key: gestureKeys.settings,
            padding: EdgeInsets.only(
              top: DesktopWindowFrame.captionSafeTopInset,
              right: DesktopWindowFrame.captionSafeTopInset == 0
                  ? DesktopWindowFrame.trailingInset
                  : RevericSpacing.lg,
            ),
            child: SizedBox(
              height: DesktopWindowFrame.titleBarHeight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ProductionScreenplayStyle(service: service),
                  Container(
                    width: 1,
                    height: RevericSpacing.x2l,
                    margin: const EdgeInsets.symmetric(
                      horizontal: RevericSpacing.sm,
                    ),
                    color: colors.borderSubtle,
                  ),
                  ProductionSpecChip(
                    path: novel.contentDatabasePath!,
                    episodeId: '',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
