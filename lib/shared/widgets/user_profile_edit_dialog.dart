// 职责: 用户资料编辑对话框 — 修改用户名与头像，头像文件复制到应用支持目录保证持久可访问。
// 关联文件:
//   lib/shared/components/reveric_dialog.dart
//   lib/shared/components/reveric_button.dart
//   lib/mobile/pages/settings_page.dart
//   lib/shared/providers/settings_providers.dart
//   lib/shared/utils/storage_paths.dart
//   lib/shared/utils/avatar_storage.dart
//   lib/shared/widgets/user_avatar.dart

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../localization/app_localization.dart';
import '../localization/locale_keys.dart';
import '../providers/settings_providers.dart';
import '../theme/theme.dart';
import '../utils/avatar_storage.dart';
import '../utils/storage_paths.dart';
import 'user_avatar.dart';
import '../components/reveric_dialog.dart';
import '../components/reveric_button.dart';

class UserProfileEditDialog extends HookConsumerWidget {
  const UserProfileEditDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = RevericTheme.colorsOf(context);
    final typo = RevericTheme.typographyOf(context);
    final settingsAsync = ref.watch(appSettingsProvider);
    final settings = settingsAsync.asData?.value;

    final usernameController = useTextEditingController(
      text: settings?.username ?? '',
    );
    final avatarPath = useState<String>(settings?.avatarPath ?? '');
    final isSaving = useState(false);
    // 存储值可能是相对/旧绝对路径；预览统一过 resolveStored 兜底。
    final resolvedAvatar = RevericPaths.resolveStored(avatarPath.value);

    Future<void> pickAvatar() async {
      final result = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'images',
            // 桌面端按扩展名过滤；iOS 要求 UTI，public.image 覆盖全部图片类型。
            extensions: ['png', 'jpg', 'jpeg', 'webp', 'gif'],
            uniformTypeIdentifiers: ['public.image'],
          ),
        ],
      );
      if (result != null) {
        avatarPath.value = await storeAvatarFile(result.path);
      }
    }

    Future<void> save() async {
      if (isSaving.value) return;
      isSaving.value = true;
      try {
        final notifier = ref.read(appSettingsProvider.notifier);
        final navigator = Navigator.of(context);
        await notifier.setUsername(usernameController.text.trim());
        await notifier.setAvatarPath(
          RevericPaths.toRelative(avatarPath.value) ?? avatarPath.value,
        );
        if (navigator.mounted) {
          navigator.pop();
        }
      } finally {
        isSaving.value = false;
      }
    }

    return RevericDialog.panel(
      title: Text(context.t(LocaleKeys.onboardingUserProfileTitle)),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: GestureDetector(
                onTap: pickAvatar,
                child: Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colors.surfaceDim,
                    border: Border.all(color: colors.borderInput, width: 2),
                  ),
                  // 只让头像跟随昵称输入重建，不牵动输入框。
                  child: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: usernameController,
                    builder: (_, value, _) => UserAvatar(
                      username: value.text,
                      imagePath: resolvedAvatar,
                      size: 84,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: RevericSpacing.xs),
            Center(
              child: TextButton(
                onPressed: pickAvatar,
                child: Text(context.t(LocaleKeys.onboardingAvatarSelect)),
              ),
            ),
            const SizedBox(height: RevericSpacing.lg),
            Text(
              context.t(LocaleKeys.onboardingUsernameLabel),
              style: typo.uiSmallSemibold.copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: RevericSpacing.xs),
            TextField(
              controller: usernameController,
              style: typo.uiSmall.copyWith(color: colors.textPrimary),
              decoration: InputDecoration(
                hintText: context.t(LocaleKeys.onboardingUsernameHint),
                hintStyle: typo.uiSmall.copyWith(color: colors.textMuted),
                filled: true,
                fillColor: colors.canvas,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(RevericRadius.medium),
                  borderSide: BorderSide(color: colors.borderInput),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(RevericRadius.medium),
                  borderSide: BorderSide(color: colors.borderInput),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(RevericRadius.medium),
                  borderSide: BorderSide(color: colors.accent),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: RevericSpacing.md,
                  vertical: RevericSpacing.sm,
                ),
              ),
            ),
          ],
        ),
      ),

      width: 360 + RevericSpacing.x4l * 2,

      actions: [
        RevericButton.secondary(
          label: context.t(LocaleKeys.commonCancel),
          onPressed: () => Navigator.of(context).pop(),
        ),
        RevericButton.primary(
          label: context.t(LocaleKeys.commonSave),
          onPressed: save,
        ),
      ],
    );
  }
}
