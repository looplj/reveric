// 职责: 移动端角色分区列表 — 列出角色（头像 + 名称 + 角色标签 + 摘要预览）、新建、左滑删除、点击进入角色编辑页。
// 关联文件:
//   lib/mobile/pages/character_editor_page.dart
//   lib/mobile/widgets/section_scaffold.dart
//   lib/mobile/widgets/delete_confirm.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/services/novel_content.dart
//   lib/shared/models/character_profile.dart
//   lib/shared/widgets/character_avatar.dart
//   lib/shared/widgets/screenplay/labels.dart
//   lib/shared/theme/theme.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/character.json
//   assets/translations/zh-CN/character.json
//   assets/translations/en/common.json
//   assets/translations/zh-CN/common.json
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json
// 遵循的 Rules:
//   .agents/rules/state-management.md
//   .agents/rules/design-system.md
//   .agents/rules/icons.md
//   .agents/rules/i18n.md
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/database/novel_content_database.dart';
import '../../shared/localization/app_localization.dart';
import '../../shared/localization/locale_keys.dart';
import '../../shared/models/character_profile.dart';
import '../../shared/providers/novel_providers.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/character_avatar.dart';
import '../../shared/widgets/screenplay/labels.dart';
import '../pages/character_editor_page.dart';
import 'delete_confirm.dart';
import 'section_scaffold.dart';

class MobileCharactersPanel extends ConsumerWidget {
  const MobileCharactersPanel({
    super.key,
    required this.databasePath,
    required this.novelId,
    required this.onCreate,
    this.onOpenGraph,
    this.isScreenplay = false,
  });

  final String databasePath;
  final String novelId;

  /// 新建入口由标题栏右上角承载；空状态引导按钮复用同一回调。
  final VoidCallback onCreate;

  /// 人物档案「关系网络」分组跳转关系图；由 page 层切分区实现。
  final VoidCallback? onOpenGraph;

  /// 剧本作品没有章节，人物档案里的「本作首次出场」整行隐藏。
  final bool isScreenplay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(characterProfilesProvider(databasePath));
    final characters = async.asData?.value ?? const <CharacterProfile>[];
    final enabled = characters.enabled.sorted;

    if (async.isLoading && characters.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    Future<void> openEditor(CharacterProfile c) async {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MobileCharacterEditorPage(
            novelId: novelId,
            databasePath: databasePath,
            characterId: c.id,
            onOpenGraph: onOpenGraph,
            isScreenplay: isScreenplay,
          ),
        ),
      );
    }

    Future<void> deleteEntry(CharacterProfile c) async {
      final service = ref.read(novelContentServiceProvider(databasePath));
      final confirmed = await showMobileDeleteConfirm(
        context,
        title: c.name,
        blockedReason: screenplayInUseBlockedReason(
          context,
          introKey: LocaleKeys.screenplayCharacterInUse,
          references: service.getCharacterScreenplayScenes(c.id),
        ),
      );
      if (!confirmed) {
        return;
      }
      await service.deleteCharacterProfile(c.id);
    }

    // 新建入口由外部标题栏承载；空状态仍保留引导按钮（走 onCreate）。
    return MobileSectionListScaffold(
      createLabel: context.t(LocaleKeys.workspaceNewCharacter),
      onCreate: onCreate,
      showCreateBar: false,
      emptyIcon: RevericIcons.person,
      emptySectionLabel: context.t(LocaleKeys.workspaceCharacters),
      emptyHint: context.t(LocaleKeys.workspaceCharactersHint),
      itemCount: enabled.length,
      itemBuilder: (_, index) => _CharacterCard(
        c: enabled[index],
        onTap: openEditor,
        onDelete: deleteEntry,
      ),
    );
  }
}

class _CharacterCard extends StatelessWidget {
  const _CharacterCard({
    required this.c,
    required this.onTap,
    required this.onDelete,
  });

  final CharacterProfile c;
  final ValueChanged<CharacterProfile> onTap;
  final ValueChanged<CharacterProfile> onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final name = c.name.trim().isEmpty
        ? context.t(LocaleKeys.commonUntitled)
        : c.name.trim();
    final roleLabel = _roleLabel(context, c.normalizedRole);
    final roleBadgeColors = _roleBadgeColors(colors, c.normalizedRole);
    final summary = c.biographyPreview.trim();

    return MobileSectionCard(
      onTap: () => onTap(c),
      onDelete: () => onDelete(c),
      deleteLabel: context.t(LocaleKeys.commonDelete),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          CharacterAvatar(
            character: c,
            size: 46,
            backgroundColor: colors.accent.withValues(alpha: 0.2),
            textColor: colors.accent,
          ),
          const SizedBox(width: RevericSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: typo.uiSemibold.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: RevericSpacing.xs),
                    MobileSectionTagChip(
                      label: roleLabel,
                      backgroundColor: roleBadgeColors.$1,
                      foregroundColor: roleBadgeColors.$2,
                    ),
                  ],
                ),
                if (summary.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    summary,
                    style: typo.uiSmall.copyWith(
                      color: colors.textSecondary,
                      height: 1.5,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (c.tags.isNotEmpty) ...[
                  const SizedBox(height: RevericSpacing.xs),
                  Text(
                    c.tags.join(' · '),
                    style: typo.uiTiny.copyWith(color: colors.textMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: RevericSpacing.sm),
          const MobileSectionTrailingChevron(),
        ],
      ),
    );
  }
}

String _roleLabel(BuildContext context, String role) {
  return switch (role) {
    characterRoleProtagonist => context.t(LocaleKeys.characterRoleProtagonist),
    characterRoleAntagonist => context.t(LocaleKeys.characterRoleAntagonist),
    characterRoleSupporting => context.t(LocaleKeys.characterRoleSupporting),
    characterRoleMinor => context.t(LocaleKeys.characterRoleMinor),
    _ => context.t(LocaleKeys.characterRoleSupporting),
  };
}

(Color background, Color foreground) _roleBadgeColors(
  RevericColors colors,
  String role,
) {
  return switch (role) {
    characterRoleProtagonist => (
      colors.accentWarm.withValues(alpha: 0.12),
      colors.accentWarm,
    ),
    characterRoleAntagonist => (
      colors.error.withValues(alpha: 0.12),
      colors.error,
    ),
    characterRoleMinor => (
      colors.textSubtle.withValues(alpha: 0.13),
      colors.textSubtle,
    ),
    _ => (colors.surfaceDim, colors.textMuted),
  };
}
