// 职责: 选择要随画布归档的已保存会话，发布与本机导出共用。
// 关联文件:
//   lib/desktop/features/canvas_gallery/publish_dialog.dart
//   lib/desktop/features/production/package_actions.dart
//   lib/shared/services/production/canvas_package.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/production.json
//   assets/translations/zh-CN/production.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/hooks.md
//   .agents/rules/icons.md

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../../shared/components/reveric_badge.dart';
import '../../../shared/components/reveric_button.dart';
import '../../../shared/components/reveric_checkbox.dart';
import '../../../shared/components/reveric_dialog.dart';
import '../../../shared/components/reveric_placeholder.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/logger/app_logger.dart';
import '../../../shared/services/production/canvas_package.dart';
import '../../../shared/theme/theme.dart';
import 'gallery_frame.dart';

class CanvasConversationSelection extends StatelessWidget {
  const CanvasConversationSelection({
    super.key,
    required this.sessions,
    required this.selected,
    required this.onChanged,
    required this.onReplace,
    this.scrollable = false,
  });

  final List<ProductionCanvasPackageConversation> sessions;
  final Set<String> selected;
  final void Function(String sessionId, bool selected) onChanged;
  final ValueChanged<Set<String>> onReplace;

  /// 为 true 时在有限高度容器内让会话列表独立滚动，固定顶部标题行。
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);

    final header = Row(
      children: [
        Expanded(
          child: Text(
            context.t(LocaleKeys.productionGalleryChooseConversations),
            style: typo.uiSemibold.copyWith(color: colors.textPrimary),
          ),
        ),
        if (selected.isNotEmpty) ...[
          RevericBadge(
            label: context.t(
              LocaleKeys.commonSelectedCountFmt,
              namedArgs: {'count': '${selected.length}'},
            ),
            color: colors.accent,
          ),
          const SizedBox(width: RevericSpacing.sm),
        ],
        if (sessions.isNotEmpty) ...[
          RevericButton.secondary(
            size: RevericButtonSize.compact,
            label: context.t(LocaleKeys.commonSelectAll),
            onPressed: selected.length == sessions.length
                ? null
                : () => onReplace({
                    for (final session in sessions) session.summary.id,
                  }),
          ),
          const SizedBox(width: RevericSpacing.sm),
          RevericButton.secondary(
            size: RevericButtonSize.compact,
            label: context.t(LocaleKeys.commonDeselectAll),
            onPressed: selected.isEmpty ? null : () => onReplace({}),
          ),
        ],
      ],
    );

    if (sessions.isEmpty) {
      final empty = Container(
        padding: const EdgeInsets.all(RevericSpacing.x3l),
        decoration: BoxDecoration(
          color: colors.surfaceDim.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(RevericRadius.x2l),
          border: Border.all(color: colors.borderSubtle),
        ),
        child: RevericPlaceholder.empty(
          icon: RevericIcons.chat_bubble_outline,
          title: context.t(LocaleKeys.productionGalleryConversationsNone),
          compact: true,
        ),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: scrollable ? MainAxisSize.max : MainAxisSize.min,
        children: [
          header,
          const SizedBox(height: RevericSpacing.md),
          if (scrollable) Expanded(child: Center(child: empty)) else empty,
        ],
      );
    }

    Widget buildCard(ProductionCanvasPackageConversation session) {
      final id = session.summary.id;
      return _ConversationOptionCard(
        key: ValueKey(id),
        session: session,
        checked: selected.contains(id),
        onToggleChecked: (checked) => onChanged(id, checked),
      );
    }

    if (scrollable) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const SizedBox(height: RevericSpacing.md),
          Expanded(
            child: ListView.separated(
              itemCount: sessions.length,
              separatorBuilder: (_, _) =>
                  const SizedBox(height: RevericSpacing.sm),
              itemBuilder: (_, index) => buildCard(sessions[index]),
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        header,
        const SizedBox(height: RevericSpacing.md),
        for (final (index, session) in sessions.indexed) ...[
          if (index > 0) const SizedBox(height: RevericSpacing.sm),
          buildCard(session),
        ],
      ],
    );
  }
}

class _ConversationOptionCard extends StatelessWidget {
  const _ConversationOptionCard({
    super.key,
    required this.session,
    required this.checked,
    required this.onToggleChecked,
  });

  final ProductionCanvasPackageConversation session;
  final bool checked;
  final ValueChanged<bool> onToggleChecked;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final summary = session.summary;
    final radius = BorderRadius.circular(RevericRadius.x2l);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: checked ? colors.accent.withValues(alpha: 0.05) : colors.surface,
        borderRadius: radius,
        border: Border.all(
          color: checked
              ? colors.accent.withValues(alpha: 0.4)
              : colors.borderSubtle,
        ),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: MergeSemantics(
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.only(
                  start: RevericSpacing.xs,
                ),
                child: RevericCheckbox(
                  value: checked,
                  onChanged: (value) => onToggleChecked(value == true),
                ),
              ),
              Expanded(
                child: InkWell(
                  onTap: () => onToggleChecked(!checked),
                  hoverColor: colors.hover.withValues(alpha: 0.45),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      RevericSpacing.xs,
                      RevericSpacing.md,
                      RevericSpacing.md,
                      RevericSpacing.md,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          summary.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: typo.uiMedium.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          [
                            galleryDate(context, summary.updatedAt),
                            context.t(
                              LocaleKeys.productionGalleryConversationContents,
                              namedArgs: {
                                'messages': '${summary.messageCount}',
                                'files': '${summary.fileCount}',
                              },
                            ),
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: typo.uiTiny.copyWith(
                            color: colors.textMuted,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final _log = AppLogger.forModule('CanvasConversationSelection');

Future<Set<String>?> showCanvasConversationSelection(
  BuildContext context, {
  required Future<List<ProductionCanvasPackageConversation>> Function() load,
}) async {
  final sessions = await load()
      .then<List<ProductionCanvasPackageConversation>?>(
        (sessions) => sessions,
        onError: (Object error, StackTrace stackTrace) {
          _log.error(
            'Could not load conversations for local export',
            error: error,
            stackTrace: stackTrace,
          );
          return null;
        },
      );
  if (!context.mounted) {
    return null;
  }
  if (sessions?.isEmpty ?? false) {
    return {};
  }
  return showRevericDialog<Set<String>>(
    context: context,
    builder: (_) => _LocalSelectionDialog(sessions: sessions),
  );
}

class _LocalSelectionDialog extends HookWidget {
  const _LocalSelectionDialog({required this.sessions});

  final List<ProductionCanvasPackageConversation>? sessions;

  @override
  Widget build(BuildContext context) {
    final selected = useState<Set<String>>({});
    final sessions = this.sessions;
    final maxHeight = math.min(
      460.0,
      math.max(240.0, MediaQuery.sizeOf(context).height - 200),
    );

    return RevericDialog.panel(
      title: Text(context.t(LocaleKeys.commonExport)),
      width: RevericSizes.productionTrimDialogWidth,
      content: sessions == null
          ? GalleryNoticeBanner(
              message: context.t(LocaleKeys.productionGallerySessionsFailed),
            )
          : SizedBox(
              height: maxHeight,
              child: CanvasConversationSelection(
                sessions: sessions,
                selected: selected.value,
                scrollable: true,
                onChanged: (id, checked) {
                  selected.value = toggleCanvasConversation(
                    selected.value,
                    id,
                    checked,
                  );
                },
                onReplace: (next) => selected.value = next,
              ),
            ),
      actions: [
        RevericButton.secondary(
          label: context.t(LocaleKeys.commonCancel),
          onPressed: Navigator.of(context).pop,
        ),
        RevericButton.primary(
          label: context.t(LocaleKeys.commonExport),
          onPressed: () => Navigator.of(context).pop(selected.value),
        ),
      ],
    );
  }
}

Set<String> toggleCanvasConversation(
  Set<String> selected,
  String id,
  bool checked,
) => checked ? {...selected, id} : ({...selected}..remove(id));
