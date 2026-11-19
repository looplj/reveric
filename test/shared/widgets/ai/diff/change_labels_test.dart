// 职责: 验证变更面板的资源名称、旧路径兼容、中英文字段标签与两端渲染。
// 关联文件:
//   lib/shared/widgets/ai/diff/change_labels.dart
//   lib/shared/widgets/ai/diff/recent_changes_log.dart
//   lib/desktop/widgets/ai/diff/pending_changes_detail_dialog.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/workspace.json
//   assets/translations/zh-CN/workspace.json
//   assets/translations/en/screenplay.json
//   assets/translations/zh-CN/screenplay.json

import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reveric/shared/components/dialog_feedback.dart';
import 'package:reveric/desktop/widgets/ai/diff/pending_changes_detail_dialog.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/services/novel_content.dart';
import 'package:reveric/shared/services/working_change_summary.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/ai/diff/change_labels.dart';
import 'package:reveric/shared/widgets/ai/diff/recent_changes_log.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NovelContentDatabase db;
  late NovelContentService service;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    if (Platform.environment['REVERIC_CHANGE_SCREENSHOTS'] != null) {
      for (final family in ['Roboto', 'Georgia', 'Menlo', 'monospace']) {
        final font = FontLoader(family)
          ..addFont(rootBundle.load('assets/fonts/LXGWWenKai-Regular.ttf'));
        await font.load();
      }
    }
  });
  setUp(() {
    rootBundle.clear();
    db = NovelContentDatabase.forTest(NativeDatabase.memory());
    service = NovelContentService(db);
  });
  tearDown(() async => db.close());

  test('resolves episodes, scenes, locations and creatures', () async {
    final initial = await ScreenplayService(db).createInitialStructure();
    final episodes = await resolveChangeResourceTitle([
      _change('screenplay_episodes', initial.episodeId, 'outline'),
    ], service);
    expect(episodes.ordinals, {
      LocaleKeys.screenplaySeason: 1,
      LocaleKeys.screenplayEpisode: 1,
    });
    await ScreenplayService(db).createScene(
      screenplayId: (await db.screenplayDao.getRoot())!.id,
      episodeId: initial.episodeId,
    );
    final scenes = await db.screenplayDao.getSceneRows(initial.episodeId);
    final scene = await resolveChangeResourceTitle([
      _change('screenplay_scenes', scenes.first.id, 'elements'),
    ], service);
    expect(scene.ordinals[LocaleKeys.screenplayScene], 1);
    final location = await service.locationsService.createLocation(
      name: '山间木屋',
    );
    final creature = await service.createItem(type: 'creature', title: '雪鸮');
    expect(
      (await resolveChangeResourceTitle([
        _change('locations', location, 'description'),
      ], service)).title,
      '山间木屋',
    );
    expect(
      (await resolveChangeResourceTitle([
        _change('creatures', creature, 'content'),
      ], service)).title,
      '雪鸮',
    );
  });

  test(
    'resolves volume title and number, including untitled volumes',
    () async {
      final id = await service.createVolume(title: '风起');
      final title = await resolveChangeResourceTitle([
        _change('volumes', id, 'outline'),
        _change('volumes', id, null, preview: '旧标题\n\n旧大纲'),
      ], service);
      expect(title.title, '风起');
      expect(title.ordinals, {LocaleKeys.workspaceVolumeNumber: 1});

      final untitledId = await service.createVolume(title: '  ');
      final untitled = await resolveChangeResourceTitle([
        _change('volumes', untitledId, 'title'),
      ], service);
      expect(untitled.title, isEmpty);
      expect(untitled.ordinals, {LocaleKeys.workspaceVolumeNumber: 2});
    },
  );

  for (final type in ['volumes', 'outlines']) {
    test('missing $type uses creation title but never edit text', () async {
      final edited = _change(
        type,
        'removed',
        'outline',
        preview: '这行是编辑正文，不是标题',
      );
      final created = _change(
        type,
        'removed',
        null,
        preview: '  风起  \n\n创建时的大纲正文',
      );
      final title = await resolveChangeResourceTitle([
        edited,
        created,
      ], service);
      expect(title.title, '风起');
      expect(title.ordinals, isEmpty);
      expect(
        (await resolveChangeResourceTitle([edited], service)).title,
        '$type/removed/outline',
      );
    });
  }

  test(
    'missing resource uses known creation preview or relative path',
    () async {
      final created = _change(
        'characters',
        'removed',
        null,
        preview: '林岚\n\n角色：supporting',
      );
      expect(
        (await resolveChangeResourceTitle([created], service)).title,
        '林岚',
      );
      final missing = _change('screenplay_episodes', 'removed', 'outline');
      expect(
        (await resolveChangeResourceTitle([missing], service)).title,
        'episodes/removed/outline',
      );
      final legacy = missing.copyWith(resourceId: const Value(null));
      final relative = legacy.copyWith(
        resourcePath: 'episodes/removed/outline',
      );
      expect(countChangeGroups([legacy, relative]), 1);
    },
  );

  for (final locale in [const Locale('en'), const Locale('zh', 'CN')]) {
    testWidgets('detail and mobile labels in $locale', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final zh = locale.languageCode == 'zh';
      final change = _change('screenplay_episodes', 'removed', 'outline');
      final item = PendingChangesDetailItem(
        changes: [change],
        fields: [
          WorkingFieldReview(changes: [change], currentText: change.newText),
        ],
        title: 'episodes/removed/outline',
        subtitle: zh ? '大纲' : 'Outline',
        delta: (added: 5, removed: 0),
        resourceType: 'screenplay_episodes',
      );
      await tester.pumpWidget(
        _wrap(
          locale,
          service,
          PendingChangesDetailDialog(
            novelId: 'work',
            databasePath: 'test',
            items: [item],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(zh ? '1 项资源已更改' : 'Resources changed: 1'),
        findsOneWidget,
      );
      expect(find.text('outline'), findsNothing);
      expect(find.text(zh ? '大纲' : 'Outline'), findsWidgets);
      final context = tester.element(find.byType(PendingChangesDetailDialog));
      expect(
        changeFieldLabel(context, 'locations', 'description'),
        zh ? '描述' : 'Description',
      );
      expect(
        changeFieldLabel(context, 'novel', 'description'),
        isNot(changeFieldLabel(context, 'locations', 'description')),
      );
      expect(
        changeFieldLabel(context, 'screenplay_scenes', 'synopsis'),
        zh ? '梗概' : 'Synopsis',
      );
      expect(tester.takeException(), isNull);
      if (zh) {
        await _screenshot(tester, 'desktop');
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpWidget(
        _wrap(
          locale,
          service,
          RecentChangesLog(
            novelId: 'work',
            databasePath: 'test',
            changes: [change],
            bounded: false,
          ),
        ),
      );
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(find.text('episodes/removed/outline'), findsOneWidget);
      expect(find.text(zh ? '大纲' : 'Outline'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (zh) {
        await _screenshot(tester, 'mobile');
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }
}

WorkingChange _change(
  String type,
  String id,
  String? field, {
  String? preview,
}) {
  final collection = type.replaceFirst('screenplay_', '');
  return WorkingChange(
    id: '$id-${field ?? 'create'}',
    resourcePath: '/$collection/$id${field == null ? '' : '/$field'}',
    resourceType: type,
    resourceId: id,
    field: field,
    changeType: field == null ? 'create' : 'write',
    source: 'ai',
    summary: '',
    oldText: '',
    newText: preview ?? '测试集大纲：验证集字段读写。',
    baseVersion: 0,
    status: 'committed',
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );
}

Widget _wrap(Locale locale, NovelContentService service, Widget child) {
  return ProviderScope(
    overrides: [
      novelContentServiceProvider('test').overrideWithValue(service),
      workingFieldReviewsProvider.overrideWith(
        (ref, args) => Stream.value([
          for (final change in args.$2)
            WorkingFieldReview(changes: [change], currentText: change.newText),
        ]),
      ),
    ],
    child: EasyLocalization(
      key: ValueKey(locale),
      supportedLocales: const [Locale('en'), Locale('zh', 'CN')],
      path: 'assets/translations',
      assetLoader: const MergingAssetLoader(),
      fallbackLocale: const Locale('en'),
      startLocale: locale,
      saveLocale: false,
      child: Builder(
        builder: (context) => MaterialApp(
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          locale: context.locale,
          theme: RevericThemeData.reveric.toThemeData(fontFamily: 'Roboto'),
          home: RevericTheme(
            data: RevericThemeData.reveric,
            child: Scaffold(
              body: RepaintBoundary(
                key: const ValueKey('change-screenshot'),
                child: DialogFeedback.scope(builder: (_) => child),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _screenshot(WidgetTester tester, String name) async {
  final directory = Platform.environment['REVERIC_CHANGE_SCREENSHOTS'];
  if (directory == null) {
    return;
  }
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('change-screenshot')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(
      '$directory/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
