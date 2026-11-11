// 职责: 桌面端首页问候区 — 展示时段问候、最近作品提示与新建/导入快捷操作
// 关联文件:
//   lib/desktop/widgets/home/library_home_panel.dart
//   lib/desktop/widgets/desktop_window_frame.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/home.json
//   assets/translations/zh-CN/home.json
//   assets/translations/en/library.json
//   assets/translations/zh-CN/library.json

import 'package:flutter/material.dart';

import '../../../shared/components/reveric_button.dart';
import '../../../shared/localization/app_localization.dart';
import '../../../shared/localization/locale_keys.dart';
import '../../../shared/theme/theme.dart';
import '../desktop_window_frame.dart';

String _greetingKey(int hour) {
  if (hour >= 5 && hour < 12) return LocaleKeys.homeGreetingMorning;
  if (hour >= 12 && hour < 18) return LocaleKeys.homeGreetingAfternoon;
  if (hour >= 18 && hour < 23) return LocaleKeys.homeGreetingEvening;
  return LocaleKeys.homeGreetingNight;
}

String _greetingShortKey(int hour) {
  if (hour >= 5 && hour < 12) return LocaleKeys.homeGreetingMorningShort;
  if (hour >= 12 && hour < 18) return LocaleKeys.homeGreetingAfternoonShort;
  if (hour >= 18 && hour < 23) return LocaleKeys.homeGreetingEveningShort;
  return LocaleKeys.homeGreetingNightShort;
}

class GreetingHeader extends StatelessWidget {
  const GreetingHeader({
    super.key,
    required this.onQuickStart,
    required this.onCreateNovel,
    required this.createLabel,
    required this.onImport,
    required this.importLabel,
    required this.username,
    required this.featuredTitle,
    required this.headerGestureExclusionKey,
  });

  /// 为 null 时不显示快速开书（剧本库）。
  final VoidCallback? onQuickStart;
  final VoidCallback onCreateNovel;
  final String createLabel;

  /// 小说库导入 TXT，剧本库导入后交给 AI 改编。
  final VoidCallback? onImport;
  final String importLabel;
  final String? username;
  final String? featuredTitle;
  final GlobalKey headerGestureExclusionKey;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final hour = DateTime.now().hour;
    final name = username;

    final title = featuredTitle;
    final String headline;
    if (name == null) {
      headline = context.t(_greetingKey(hour));
    } else if (title != null && title.isNotEmpty) {
      headline = context.t(
        LocaleKeys.homeGreetingPersonalized,
        namedArgs: {
          'greeting': context.t(_greetingShortKey(hour)),
          'name': name,
          'title': title,
        },
      );
    } else {
      headline = context.t(
        LocaleKeys.homeGreetingPersonalizedSimple,
        namedArgs: {
          'greeting': context.t(_greetingShortKey(hour)),
          'name': name,
        },
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 问候语保持原味，居于顶部。
        Padding(
          padding: EdgeInsets.only(right: DesktopWindowFrame.trailingInset),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  headline,
                  style: typo.heading2.copyWith(
                    color: colors.textPrimary,
                    fontSize: 26,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: RevericSpacing.sm),
              RevericIcon(
                RevericIcons.auto_awesome,
                size: 24,
                color: colors.accentAmber,
              ),
            ],
          ),
        ),
        const SizedBox(height: RevericSpacing.xl),
        // 操作区位于问候下方，右对齐；窄窗口按按钮整体换行。
        // 这个 key 会被 DesktopWindowFrame 用来排除标题栏拖拽命中；
        // 否则双击按钮可能同时触发窗口缩放。
        KeyedSubtree(
          key: headerGestureExclusionKey,
          child: SizedBox(
            width: double.infinity,
            child: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: RevericSpacing.sm,
              runSpacing: RevericSpacing.sm,
              children: [
                if (onImport != null)
                  OutlinedButton.icon(
                    onPressed: onImport,
                    icon: const RevericIcon(RevericIcons.upload, size: 16),
                    label: Text(importLabel),
                  ),
                // 新建作品 — 有快速开书时是次按钮（outlined），走完整表单对话框；
                // 没有时它就是唯一的主操作。
                if (onQuickStart case final quickStart?) ...[
                  OutlinedButton.icon(
                    onPressed: onCreateNovel,
                    icon: const RevericIcon(RevericIcons.add, size: 16),
                    label: Text(createLabel),
                  ),
                  // 快速开书 — 主按钮（accent）：占位建书后进编辑器走创作向导。
                  RevericButton.primary(
                    onPressed: quickStart,
                    icon: RevericIcons.auto_awesome,
                    label: context.t(LocaleKeys.libraryQuickStart),
                    size: RevericButtonSize.prominent,
                  ),
                ] else
                  RevericButton.primary(
                    onPressed: onCreateNovel,
                    icon: RevericIcons.add,
                    label: createLabel,
                    size: RevericButtonSize.prominent,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
