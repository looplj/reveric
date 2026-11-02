// 职责: 展示本地用户名和头像，点击后编辑本地资料。
// 关联文件:
//   lib/shared/providers/settings_providers.dart
//   lib/shared/theme/theme.dart
//   lib/shared/utils/storage_paths.dart
//   lib/desktop/widgets/settings/settings_dialog.dart
//   lib/shared/widgets/user_profile_edit_dialog.dart (本地资料编辑)
//   lib/shared/widgets/user_avatar.dart
import '../../shared/components/reveric_dialog.dart';
import '../../shared/widgets/user_avatar.dart';
import '../../shared/widgets/user_profile_edit_dialog.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/providers/settings_providers.dart';
import '../../shared/theme/theme.dart';
import '../../shared/utils/storage_paths.dart';

/// 用户信息栏的布局模式。
enum UserProfileBarMode {
  /// 宽侧边栏（如首页 280px）— 大头像 + 用户名 + 右侧箭头。
  generous,

  /// 窄侧边栏（如小说编辑页 rail 132px）— 小头像 + 用户名，无箭头。
  dense,

  /// 仅头像，居中（折叠后的窄轨）。
  iconOnly,
}

class UserProfileBar extends ConsumerWidget {
  const UserProfileBar({super.key, this.mode = UserProfileBarMode.generous});

  final UserProfileBarMode mode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final settingsAsync = ref.watch(appSettingsProvider);

    return settingsAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (settings) {
        final username = settings.username.isNotEmpty
            ? settings.username
            : 'Reveric';
        final resolvedAvatar = RevericPaths.resolveStored(settings.avatarPath);

        final avatarSize = switch (mode) {
          UserProfileBarMode.generous => RevericSizes.avatarRadiusLg * 2,
          UserProfileBarMode.dense => 22.0,
          UserProfileBarMode.iconOnly => RevericSizes.aiAvatarSm,
        };

        void openAccount() {
          showRevericDialog<void>(
            context: context,
            builder: (_) => const UserProfileEditDialog(),
          );
        }

        final avatar = UserAvatar(
          username: username,
          imagePath: resolvedAvatar,
          size: avatarSize,
        );

        if (mode == UserProfileBarMode.iconOnly) {
          return InkWell(
            onTap: openAccount,
            hoverColor: colors.hover,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: RevericSpacing.md),
              child: Center(child: avatar),
            ),
          );
        }

        if (mode == UserProfileBarMode.dense) {
          return InkWell(
            onTap: openAccount,
            hoverColor: colors.hover,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: RevericSpacing.sm,
                vertical: RevericSpacing.sm,
              ),
              child: Row(
                children: [
                  avatar,
                  const SizedBox(width: RevericSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          username,
                          style: typo.uiSmall.copyWith(
                            color: colors.textPrimary,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        // generous
        return InkWell(
          onTap: openAccount,
          hoverColor: colors.hover,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: RevericSpacing.x2l,
              vertical: RevericSpacing.lg,
            ),
            child: Row(
              children: [
                avatar,
                const SizedBox(width: RevericSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        username,
                        style: typo.uiSemibold.copyWith(
                          color: colors.textPrimary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: RevericSpacing.sm),
                RevericIcon(
                  RevericIcons.keyboard_arrow_right,
                  size: 18,
                  color: colors.textSubtle,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
