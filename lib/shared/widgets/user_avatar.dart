// 职责: 渲染本地用户头像；未设置或图片加载失败时显示按昵称取色的首字头像。
// 关联文件:
//   lib/shared/theme/reveric_colors.dart
//   lib/desktop/widgets/user_profile_bar.dart
//   lib/mobile/pages/settings_page.dart
//   lib/shared/widgets/user_profile_edit_dialog.dart
// 遵循的 Rules:
//   .agents/rules/design-system.md

import 'dart:io';

import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// 圆形用户头像。[imagePath] 为已解析的本地图片路径，空值时显示首字头像。
class UserAvatar extends StatelessWidget {
  const UserAvatar({
    super.key,
    required this.username,
    required this.imagePath,
    required this.size,
  });

  final String username;
  final String? imagePath;
  final double size;

  @override
  Widget build(BuildContext context) {
    final path = imagePath;
    return SizedBox.square(
      dimension: size,
      child: ClipOval(
        child: path == null
            ? _Monogram(username: username, size: size)
            : Image.file(
                File(path),
                width: size,
                height: size,
                fit: BoxFit.cover,
                cacheWidth: (size * 2).toInt(),
                errorBuilder: (_, _, _) =>
                    _Monogram(username: username, size: size),
              ),
      ),
    );
  }
}

class _Monogram extends StatelessWidget {
  const _Monogram({required this.username, required this.size});

  final String username;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final name = username.trim().isEmpty ? 'Reveric' : username.trim();
    final tone = _toneFor(name);
    final glyph = String.fromCharCode(name.runes.first).toUpperCase();

    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Color.lerp(colors.surface, tone, 0.2),
        border: Border.all(color: tone.withValues(alpha: 0.26)),
      ),
      child: Center(
        child: Text(
          glyph,
          style: typo.uiSemibold.copyWith(
            color: Color.lerp(colors.textPrimary, tone, 0.72),
            fontSize: size * 0.44,
            height: 1,
          ),
        ),
      ),
    );
  }

  /// 同一昵称在各端、各次启动取到同一色。
  static Color _toneFor(String name) {
    var hash = 0;
    for (final rune in name.runes) {
      hash = (hash * 31 + rune) & 0x7fffffff;
    }
    return RevericColors.avatarTones[hash % RevericColors.avatarTones.length];
  }
}
