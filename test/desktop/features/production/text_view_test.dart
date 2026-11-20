// 职责: 验证文本节点的放大弹窗可以编辑正文，未改动关闭不记撤销，改动关闭只记一步。
// 关联文件:
//   lib/desktop/features/production/text_view.dart
//   lib/shared/services/production/canvas_service.dart
//   lib/shared/widgets/md/reveric_markdown_editor.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
//   .agents/rules/code-style.md
import 'dart:io';

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/desktop/features/production/edit_session.dart';
import 'package:reveric/desktop/features/production/history_region.dart';
import 'package:reveric/desktop/features/production/text_view.dart';
import 'package:reveric/shared/database/app_database.dart' as app;
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:reveric/shared/widgets/md/reveric_markdown_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _wrap(Widget child) => EasyLocalization(
  supportedLocales: const [Locale('en')],
  path: 'assets/translations',
  assetLoader: const MergingAssetLoader(),
  startLocale: const Locale('en'),
  fallbackLocale: const Locale('en'),
  child: Builder(
    builder: (context) => MaterialApp(
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale,
      theme: RevericThemeData.reveric.toThemeData(),
      home: RevericTheme(
        data: RevericThemeData.reveric,
        child: Scaffold(body: child),
      ),
    ),
  ),
);

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  testWidgets('enlarged text node saves edits and ignores an unchanged close', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final db = NovelContentDatabase.forTest(NativeDatabase.memory());
    final main = app.AppDatabase.forTest(NativeDatabase.memory());
    final episode = (await ScreenplayService(
      db,
    ).createInitialStructure()).episodeId;
    final service = ProductionCanvasService(
      StoryboardService(db),
      MediaLibraryService(
        main,
        MediaService(FfmpegRunner()),
        Directory.systemTemp,
      ),
      'work',
    );
    final canvas = await service.ensureCanvas(episode);
    const source = 'Short note on the card';
    final text = await service.addText(
      canvas.id,
      title: 'Note',
      content: source,
    );
    final history = CanvasHistory(service.shots, canvas.id);
    addTearDown(history.dispose);

    TextEditingController editor() => tester
        .widget<RevericMarkdownEditor>(find.byType(RevericMarkdownEditor))
        .controller;

    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(main),
            appSettingsDatabaseProvider.overrideWithValue(main),
          ],
          child: _wrap(
            ProductionHistoryScope(
              service: service,
              canvas: canvas,
              history: history,
              session: ProductionEditSession(),
              child: Builder(
                builder: (context) => TextButton(
                  onPressed: () =>
                      showProductionTextView(context, service, text),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(editor().text, source);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(RevericMarkdownEditor), findsNothing);
      expect(history.undoCount, 0);
      expect((await service.requireNode(text.id)).content, source);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      editor().text = 'Rewritten at full size';
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(RevericMarkdownEditor), findsNothing);
      expect(
        (await service.requireNode(text.id)).content,
        'Rewritten at full size',
      );
      expect(history.undoCount, 1);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await db.close();
      await main.close();
    }
  });
}
