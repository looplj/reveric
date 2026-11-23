// 职责: 验证画廊列表在宽 / 窄窗口下置顶画布进 hero、内容区居中封顶、封面保持 16:10，且有无简介的卡片都不溢出。
// 关联文件:
//   lib/desktop/features/canvas_gallery/page.dart
//   lib/desktop/features/canvas_gallery/gallery_frame.dart
//   lib/shared/services/canvas_gallery/service.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
//   .agents/rules/i18n.md

import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/desktop/features/canvas_gallery/gallery_frame.dart';
import 'package:reveric/desktop/features/canvas_gallery/page.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/ai_provider.dart';
import 'package:reveric/shared/providers/canvas_gallery_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/services/canvas_gallery/service.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/app_background.dart';
import 'package:reveric/shared/widgets/guide/trigger.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });
  setUp(() => rootBundle.clear());

  for (final width in const [1600.0, 900.0]) {
    testWidgets('lays out gallery cards without overflow at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appBackgroundActiveProvider.overrideWithValue(false),
            appSettingsProvider.overrideWith(_StaticSettingsNotifier.new),
            canvasGalleryServiceProvider.overrideWithValue(_FakeService()),
            guideTourAutoTriggerProvider.overrideWithValue(false),
          ],
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
                home: const RevericTheme(
                  data: RevericThemeData.reveric,
                  child: CanvasGalleryPage(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final covers = find.byType(GalleryCover);
      expect(covers, findsNWidgets(3));

      for (final element in covers.evaluate()) {
        final size = tester.getSize(find.byWidget(element.widget));
        expect(size.width / size.height, closeTo(16 / 10, 0.01));
      }

      final first = tester.getRect(find.text('With description'));
      final second = tester.getRect(find.text('Untitled'));
      // 同一行的卡片标题对齐，与有无简介无关。
      expect(first.top, closeTo(second.top, 0.5));

      // 置顶画布放进 hero，即使服务端把它排在后面；hero 封面比网格卡片大。
      final hero = tester.getRect(covers.first);
      final grid = tester.getRect(covers.at(1));
      expect(tester.getRect(find.text('Pinned hero')).top, lessThan(first.top));
      expect(hero.width, greaterThan(grid.width));

      if (width > RevericSizes.canvasGalleryContentMaxWidth) {
        // 宽窗口下内容区封顶并居中，卡片不再贴着窗口左缘。
        final side = (width - RevericSizes.canvasGalleryContentMaxWidth) / 2;
        expect(grid.left, greaterThanOrEqualTo(side));
      } else {
        expect(grid.left, lessThan(RevericSpacing.x6l));
      }

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }
}

class _FakeService extends CanvasGalleryService {
  _FakeService()
    : super(
        createClient: Dio.new,
        apiOrigin: Uri.parse('https://api.example.test'),
        publicOrigin: Uri.parse('https://gallery.example.test'),
      );

  @override
  Future<CanvasGalleryPageData> list({
    String? cursor,
    CancelToken? cancel,
  }) async => CanvasGalleryPageData([
    _item('a', 'With description', 'A short description.'),
    _item('b', 'Untitled', ''),
    _item('c', 'Pinned hero', 'Featured on top.', pinned: true),
  ], null);
}

CanvasGalleryItem _item(
  String id,
  String title,
  String description, {
  bool pinned = false,
}) => CanvasGalleryItem.fromJson({
  'canvas_id': id,
  'title': title,
  'description': description,
  'cover_url': 'https://gallery.example.test/$id.jpg',
  'content_size_bytes': 33030144,
  'published_at': '2026-11-20T00:00:00Z',
  'conversation_count': 5,
  'is_pinned': pinned,
});

class _StaticSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettings> build() async => AppSettings(
    theme: AppTheme.reveric,
    themeMode: AppThemeMode.dark,
    language: 'en',
    aiSettings: AiSettings.defaults(),
  );
}
