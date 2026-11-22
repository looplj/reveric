// 职责: 验证用户资料弹窗选图后即时预览、取消不落盘、保存后更新本地头像路径与外部展示。
// 关联文件:
//   lib/desktop/widgets/user_profile_bar.dart
//   lib/shared/widgets/user_profile_edit_dialog.dart
//   lib/shared/widgets/user_avatar.dart
//   lib/shared/utils/avatar_storage.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/onboarding.json
//   assets/translations/zh-CN/onboarding.json
// 遵循的 Rules:
//   .agents/rules/testing.md

import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
// Use file_selector's locked platform test interface.
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:reveric/desktop/widgets/user_profile_bar.dart';
import 'package:reveric/shared/localization/app_localization.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/utils/storage_paths.dart';
import 'package:reveric/shared/widgets/user_avatar.dart';
import 'package:reveric/shared/widgets/user_profile_edit_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeFileSelector extends FileSelectorPlatform {
  XFile? nextFile;

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    return nextFile;
  }
}

class _FakeSettingsNotifier extends AppSettingsNotifier {
  _FakeSettingsNotifier(this._initialAvatarPath);

  final String _initialAvatarPath;

  @override
  Future<AppSettings> build() async => AppSettings(
    theme: AppTheme.reveric,
    themeMode: AppThemeMode.light,
    language: 'en',
    username: 'Tester',
    avatarPath: _initialAvatarPath,
    aiSettings: AiSettings(),
  );

  @override
  Future<void> setUsername(String username) async {
    final current = state.requireValue;
    if (current.username == username) {
      return;
    }
    state = AsyncValue.data(current.copyWith(username: username));
  }

  @override
  Future<void> setAvatarPath(String avatarPath) async {
    final current = state.requireValue;
    if (current.avatarPath == avatarPath) {
      return;
    }
    state = AsyncValue.data(current.copyWith(avatarPath: avatarPath));
  }
}

/// 1x1 透明 PNG，确保 Image.file / Image.memory 在测试中可正常解码。
final _pngBytesA = Uint8List.fromList([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, //
  0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
  0x89, 0x00, 0x00, 0x00, 0x0a, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae,
  0x42, 0x60, 0x82,
]);

/// 1x1 白色 PNG（与 [_pngBytesA] 同扩展名但内容不同）。
final _pngBytesB = Uint8List.fromList([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, //
  0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
  0x89, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9c, 0x63, 0xf8, 0xff, 0xff, 0xff,
  0x7f, 0x00, 0x09, 0xfb, 0x03, 0xfd, 0x28, 0x06,
  0x50, 0xfa, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
  0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempSupport;
  late FileSelectorPlatform previousSelector;
  late _FakeFileSelector fakeSelector;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  setUp(() async {
    rootBundle.clear();
    previousSelector = FileSelectorPlatform.instance;
    fakeSelector = _FakeFileSelector();
    FileSelectorPlatform.instance = fakeSelector;

    tempSupport = await Directory.systemTemp.createTemp(
      'reveric_profile_dialog_test_',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async {
            if (call.method == 'getApplicationSupportDirectory') {
              return tempSupport.path;
            }
            return null;
          },
        );
    await RevericPaths.initialize();
  });

  tearDown(() async {
    FileSelectorPlatform.instance = previousSelector;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (await tempSupport.exists()) {
      await tempSupport.delete(recursive: true);
    }
  });

  testWidgets(
    'picking a same-extension avatar updates preview, cancel preserves disk, and save updates UserProfileBar',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // 预设已有头像 avatars/avatar.png（模拟复现路径：与新选图同扩展名）。
      final avatarsDir = Directory(p.join(tempSupport.path, 'avatars'))
        ..createSync(recursive: true);
      final initialAvatarFile = File(p.join(avatarsDir.path, 'avatar.png'))
        ..writeAsBytesSync(_pngBytesA);

      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWith(
            () => _FakeSettingsNotifier('avatars/avatar.png'),
          ),
        ],
      );
      addTearDown(container.dispose);

      late BuildContext capturedContext;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: EasyLocalization(
            supportedLocales: const [Locale('en')],
            path: 'assets/translations',
            assetLoader: const MergingAssetLoader(),
            fallbackLocale: const Locale('en'),
            startLocale: const Locale('en'),
            child: Builder(
              builder: (context) => MaterialApp(
                localizationsDelegates: context.localizationDelegates,
                supportedLocales: context.supportedLocales,
                locale: context.locale,
                theme: RevericThemeData.reveric.toThemeData(),
                builder: (_, child) =>
                    RevericTheme(data: RevericThemeData.reveric, child: child!),
                home: Scaffold(
                  body: Builder(
                    builder: (innerContext) {
                      capturedContext = innerContext;
                      return const SizedBox(
                        width: 280,
                        child: UserProfileBar(),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final initialBarAvatar = tester.widget<UserAvatar>(
        find.descendant(
          of: find.byType(UserProfileBar),
          matching: find.byType(UserAvatar),
        ),
      );
      expect(initialBarAvatar.imagePath, initialAvatarFile.path);

      // 打开资料编辑对话框。
      await tester.tap(find.byType(UserProfileBar));
      await tester.pumpAndSettle();
      expect(find.byType(UserProfileEditDialog), findsOneWidget);

      // 选择另一张同样为 .png 的图片。
      fakeSelector.nextFile = XFile.fromData(
        _pngBytesB,
        name: 'new_avatar.png',
        mimeType: 'image/png',
      );
      await tester.runAsync(() async {
        await tester.tap(
          find.text(capturedContext.t(LocaleKeys.onboardingAvatarSelect)),
        );
      });
      await tester.pumpAndSettle();

      // 预览应即时切换为新选字节，且不覆盖原 avatars/avatar.png。
      final dialogAvatarAfterPick = tester.widget<UserAvatar>(
        find.descendant(
          of: find.byType(UserProfileEditDialog),
          matching: find.byType(UserAvatar),
        ),
      );
      expect(dialogAvatarAfterPick.imageBytes, _pngBytesB);
      expect(initialAvatarFile.readAsBytesSync(), _pngBytesA);

      // 点击取消：不写入磁盘，不修改设置。
      await tester.tap(find.text(capturedContext.t(LocaleKeys.commonCancel)));
      await tester.pumpAndSettle();
      expect(find.byType(UserProfileEditDialog), findsNothing);
      expect(
        container.read(appSettingsProvider).requireValue.avatarPath,
        'avatars/avatar.png',
      );

      // 再次打开弹窗并选图后点击保存。
      await tester.tap(find.byType(UserProfileBar));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(
          find.text(capturedContext.t(LocaleKeys.onboardingAvatarSelect)),
        );
      });
      await tester.pumpAndSettle();

      await tester.runAsync(() async {
        await tester.tap(find.text(capturedContext.t(LocaleKeys.commonSave)));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      expect(find.byType(UserProfileEditDialog), findsNothing);
      final savedAvatarPath = container
          .read(appSettingsProvider)
          .requireValue
          .avatarPath;
      expect(savedAvatarPath, isNot('avatars/avatar.png'));
      expect(savedAvatarPath, startsWith('avatars/'));
      expect(savedAvatarPath, endsWith('.png'));

      final updatedBarAvatar = tester.widget<UserAvatar>(
        find.descendant(
          of: find.byType(UserProfileBar),
          matching: find.byType(UserAvatar),
        ),
      );
      final resolvedNewPath = RevericPaths.resolveStored(savedAvatarPath);
      expect(resolvedNewPath, isNotNull);
      expect(updatedBarAvatar.imagePath, resolvedNewPath);
      expect(File(resolvedNewPath!).readAsBytesSync(), _pngBytesB);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
