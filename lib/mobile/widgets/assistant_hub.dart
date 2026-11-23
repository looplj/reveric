// 职责: 移动端「助手」Hub 专用 UI — 主入口卡、AI 模式网格，以及发起对话/选择作品的交互。
// 关联文件:
//   lib/mobile/pages/chat_page.dart
//   lib/mobile/pages/novel_chat_page.dart
//   lib/mobile/features/council/page.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/models/novel.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/mobile.json
//   assets/translations/zh-CN/mobile.json
//   assets/translations/en/ai.json
//   assets/translations/zh-CN/ai.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/i18n.md
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/models/novel.dart';
import '../../shared/providers/novel_providers.dart';
import '../../shared/theme/theme.dart';
import '../features/council/page.dart';
import '../features/monologue/page.dart';
import '../pages/novel_chat_page.dart';
import '../features/roleplay/page.dart';
import '../features/theater/page.dart';

/// AI 模式占位项（圆桌会议/独白/小剧场/角色扮演）。tint 走主题 token，不硬编码。
class AssistantMode {
  const AssistantMode({
    required this.icon,
    required this.labelKey,
    required this.descKey,
    required this.tint,
  });

  final String icon;
  final String labelKey;
  final String descKey;
  final Color Function(RevericColors colors) tint;

  /// 已落地的圆桌会议模式。
  bool get isCouncil => labelKey == LocaleKeys.aiSessionModeCouncil;

  /// 已落地的独白模式。
  bool get isMonologue => labelKey == LocaleKeys.aiSessionModeMonologue;

  /// 已落地的小剧场模式。
  bool get isTheater => labelKey == LocaleKeys.aiSessionModeTheater;

  /// 已落地的角色扮演模式。
  bool get isRoleplay => labelKey == LocaleKeys.aiSessionModeRoleplay;
}

const List<AssistantMode> assistantModes = [
  AssistantMode(
    icon: RevericIcons.groups_rounded,
    labelKey: LocaleKeys.aiSessionModeCouncil,
    descKey: LocaleKeys.aiSessionModeCouncilDesc,
    tint: _tintAccent,
  ),
  AssistantMode(
    icon: RevericIcons.person_rounded,
    labelKey: LocaleKeys.aiSessionModeMonologue,
    descKey: LocaleKeys.aiSessionModeMonologueDesc,
    tint: _tintWarm,
  ),
  AssistantMode(
    icon: RevericIcons.theater_comedy_rounded,
    labelKey: LocaleKeys.aiSessionModeTheater,
    descKey: LocaleKeys.aiSessionModeTheaterDesc,
    tint: _tintSuccess,
  ),
  AssistantMode(
    icon: RevericIcons.mask_happy_rounded,
    labelKey: LocaleKeys.aiSessionModeRoleplay,
    descKey: LocaleKeys.aiSessionModeRoleplayDesc,
    tint: _tintAmber,
  ),
];

Color _tintAccent(RevericColors c) => c.accent;
Color _tintWarm(RevericColors c) => c.accentWarm;
Color _tintSuccess(RevericColors c) => c.success;
Color _tintAmber(RevericColors c) => c.accentAmber;

/// 主入口卡：写作助手 · AI · 作用于某作品 + 对话按钮。
class AssistantPrimaryEntryCard extends StatelessWidget {
  const AssistantPrimaryEntryCard({
    super.key,
    required this.novelTitle,
    required this.onTap,
  });

  /// 当前作用的作品名；为空表示尚无可用作品（点击会提示）。
  final String? novelTitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final subtitle = novelTitle == null
        ? context.t(LocaleKeys.mobileAssistantPrimarySubtitleNew)
        : context.t(
            LocaleKeys.mobileAssistantPrimarySubtitle,
            namedArgs: {'novel': novelTitle!},
          );

    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(RevericRadius.x2l),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(RevericRadius.x2l),
        child: Container(
          padding: const EdgeInsets.all(RevericSpacing.lg),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(RevericRadius.x2l),
            border: Border.all(color: colors.borderSubtle),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [colors.accent, colors.accentWarm],
                  ),
                ),
                alignment: Alignment.center,
                child: RevericIcon(
                  RevericIcons.auto_awesome,
                  size: 22,
                  color: colors.onAccent,
                ),
              ),
              const SizedBox(width: RevericSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.t(LocaleKeys.aiWritingAgent),
                      style: typo.uiSemibold.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typo.uiTiny.copyWith(color: colors.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: RevericSpacing.sm),
              FilledButton.icon(
                onPressed: onTap,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(
                    horizontal: RevericSpacing.md,
                  ),
                ),
                icon: RevericIcon(
                  RevericIcons.chat_rounded,
                  size: 15,
                  color: colors.onAccent,
                ),
                label: Text(context.t(LocaleKeys.mobileAssistantChatButton)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// AI 模式占位网格（2 列）。点击仅提示「即将上线」。
class AssistantModeGrid extends StatelessWidget {
  const AssistantModeGrid({super.key});

  @override
  Widget build(BuildContext context) {
    const gap = RevericSpacing.md;
    final rows = <Widget>[];
    for (var i = 0; i < assistantModes.length; i += 2) {
      final right = i + 1 < assistantModes.length
          ? assistantModes[i + 1]
          : null;
      // IntrinsicHeight + 拉伸的 Expanded 让同一行两张卡片等高对齐。
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _ModeCard(mode: assistantModes[i])),
              const SizedBox(width: gap),
              Expanded(
                child: right == null
                    ? const SizedBox.shrink()
                    : _ModeCard(mode: right),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: gap),
          rows[i],
        ],
      ],
    );
  }
}

class _ModeCard extends ConsumerWidget {
  const _ModeCard({required this.mode});

  final AssistantMode mode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final tint = mode.tint(colors);

    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(RevericRadius.large),
      child: InkWell(
        onTap: () {
          if (mode.isCouncil) {
            startAssistantCouncil(context, ref);
            return;
          }
          if (mode.isMonologue) {
            startAssistantMonologue(context, ref);
            return;
          }
          if (mode.isTheater) {
            startAssistantTheater(context, ref);
            return;
          }
          if (mode.isRoleplay) {
            startAssistantRoleplay(context, ref);
            return;
          }
        },
        borderRadius: BorderRadius.circular(RevericRadius.large),
        child: Container(
          padding: const EdgeInsets.all(RevericSpacing.lg),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(RevericRadius.large),
            border: Border.all(color: colors.borderSubtle),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: tint.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(RevericRadius.medium),
                    ),
                    alignment: Alignment.center,
                    child: RevericIcon(mode.icon, size: 17, color: tint),
                  ),
                  const SizedBox(width: RevericSpacing.sm),
                  Expanded(
                    child: Text(
                      context.t(mode.labelKey),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typo.uiMedium.copyWith(color: colors.textPrimary),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: RevericSpacing.sm),
              Text(
                context.t(mode.descKey),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: typo.uiTiny.copyWith(
                  color: colors.textMuted,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 当前可用于聊天的作品（有内容库），按最近更新排序。
List<Novel> assistantActiveNovels(WidgetRef ref) {
  final novels = ref.read(novelsProvider).asData?.value ?? const <Novel>[];
  final usable = novels.shelfVisible.where((n) => n.hasContentDatabase).toList()
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  return usable;
}

/// 发起对话：优先用 [preferred]，否则唯一作品直接进入，多个则弹出选择。
/// 无可用作品时提示。进入复用 [MobileNovelChatPage]（chat 模式新建会话）。
Future<void> startAssistantChat(
  BuildContext context,
  WidgetRef ref, {
  Novel? preferred,
}) async {
  final novels = assistantActiveNovels(ref);
  if (novels.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.t(LocaleKeys.mobileAssistantNoNovelHint))),
    );
    return;
  }

  final chosen =
      preferred ??
      (novels.length == 1
          ? novels.first
          : await _showAssistantNovelPicker(context, novels));
  if (chosen == null || !context.mounted) {
    return;
  }

  final databasePath = chosen.contentDatabasePath;
  if (databasePath == null || databasePath.isEmpty) {
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          MobileNovelChatPage(novelId: chosen.id, databasePath: databasePath),
    ),
  );
}

/// 发起圆桌会议：选作品流程与 [startAssistantChat] 同构，进入 [MobileCouncilPage]。
Future<void> startAssistantCouncil(
  BuildContext context,
  WidgetRef ref, {
  Novel? preferred,
}) async {
  final novels = assistantActiveNovels(ref);
  if (novels.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.t(LocaleKeys.mobileAssistantNoNovelHint))),
    );
    return;
  }

  final chosen =
      preferred ??
      (novels.length == 1
          ? novels.first
          : await _showAssistantNovelPicker(context, novels));
  if (chosen == null || !context.mounted) {
    return;
  }

  final databasePath = chosen.contentDatabasePath;
  if (databasePath == null || databasePath.isEmpty) {
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MobileCouncilPage(
        novelId: chosen.id,
        novelName: chosen.title,
        databasePath: databasePath,
        novelDescription: chosen.description,
      ),
    ),
  );
}

/// 发起独白：选作品流程与 [startAssistantChat] 同构，进入 [MobileMonologuePage]。
Future<void> startAssistantMonologue(
  BuildContext context,
  WidgetRef ref, {
  Novel? preferred,
}) async {
  final novels = assistantActiveNovels(ref);
  if (novels.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.t(LocaleKeys.mobileAssistantNoNovelHint))),
    );
    return;
  }

  final chosen =
      preferred ??
      (novels.length == 1
          ? novels.first
          : await _showAssistantNovelPicker(context, novels));
  if (chosen == null || !context.mounted) {
    return;
  }

  final databasePath = chosen.contentDatabasePath;
  if (databasePath == null || databasePath.isEmpty) {
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MobileMonologuePage(
        novelId: chosen.id,
        novelName: chosen.title,
        databasePath: databasePath,
        novelDescription: chosen.description,
      ),
    ),
  );
}

/// 发起小剧场：选作品流程与 [startAssistantChat] 同构，进入 [MobileTheaterPage]。
Future<void> startAssistantTheater(
  BuildContext context,
  WidgetRef ref, {
  Novel? preferred,
}) async {
  final novels = assistantActiveNovels(ref);
  if (novels.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.t(LocaleKeys.mobileAssistantNoNovelHint))),
    );
    return;
  }

  final chosen =
      preferred ??
      (novels.length == 1
          ? novels.first
          : await _showAssistantNovelPicker(context, novels));
  if (chosen == null || !context.mounted) {
    return;
  }

  final databasePath = chosen.contentDatabasePath;
  if (databasePath == null || databasePath.isEmpty) {
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MobileTheaterPage(
        novelId: chosen.id,
        novelName: chosen.title,
        databasePath: databasePath,
        novelDescription: chosen.description,
      ),
    ),
  );
}

/// 发起角色扮演：选作品流程与 [startAssistantChat] 同构，进入 [MobileRoleplayPage]。
Future<void> startAssistantRoleplay(
  BuildContext context,
  WidgetRef ref, {
  Novel? preferred,
}) async {
  final novels = assistantActiveNovels(ref);
  if (novels.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.t(LocaleKeys.mobileAssistantNoNovelHint))),
    );
    return;
  }

  final chosen =
      preferred ??
      (novels.length == 1
          ? novels.first
          : await _showAssistantNovelPicker(context, novels));
  if (chosen == null || !context.mounted) {
    return;
  }

  final databasePath = chosen.contentDatabasePath;
  if (databasePath == null || databasePath.isEmpty) {
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MobileRoleplayPage(
        novelId: chosen.id,
        novelName: chosen.title,
        databasePath: databasePath,
        novelDescription: chosen.description,
      ),
    ),
  );
}

Future<Novel?> _showAssistantNovelPicker(
  BuildContext context,
  List<Novel> novels,
) {
  final colors = RevericTheme.colorsOf(context);
  final typo = RevericTheme.typographyOf(context);
  return showModalBottomSheet<Novel>(
    context: context,
    backgroundColor: colors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(RevericRadius.x2l),
      ),
    ),
    builder: (sheetContext) {
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetContext).size.height * 0.7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(RevericSpacing.lg),
                child: Text(
                  sheetContext.t(LocaleKeys.mobileAssistantPickNovelTitle),
                  style: typo.uiSemibold.copyWith(color: colors.textPrimary),
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: RevericSpacing.lg),
                  itemCount: novels.length,
                  itemBuilder: (context, index) {
                    final novel = novels[index];
                    return ListTile(
                      leading: RevericIcon(
                        RevericIcons.auto_awesome,
                        size: 18,
                        color: colors.accent,
                      ),
                      title: Text(
                        novel.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typo.body.copyWith(color: colors.textPrimary),
                      ),
                      onTap: () => Navigator.of(sheetContext).pop(novel),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
