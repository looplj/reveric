// 职责: 验证画布文本节点在选中后可以拖选复制，未选中时拖动仍交给外层移动节点，双击仍进入编辑。
// 关联文件:
//   lib/desktop/features/production/text_node.dart
//   lib/shared/widgets/md/reveric_markdown_editor.dart
//   lib/shared/services/production/canvas_service.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
//   .agents/rules/code-style.md
import 'dart:io';

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/desktop/features/production/text_node.dart';
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

  testWidgets(
    'selected text node drag-selects while an unselected node still drags',
    (tester) async {
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
      const source = 'Alpha beta gamma delta';
      final text = await service.addText(
        canvas.id,
        title: 'Note',
        content: source,
      );
      String? clipboardText;
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              final args = call.arguments as Map<dynamic, dynamic>;
              clipboardText = args['text']?.toString();
            }
            return null;
          });
      var pans = 0;
      Widget board(bool selected) => RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: <Type, GestureRecognizerFactory>{
          PanGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
                () => PanGestureRecognizer(),
                (PanGestureRecognizer instance) {
                  instance.dragStartBehavior = DragStartBehavior.down;
                  instance.onStart = (_) => pans++;
                },
              ),
        },
        child: Center(
          child: SizedBox(
            width: 220,
            height: 220,
            child: ProductionTextNode(
              service: service,
              node: text,
              selected: selected,
            ),
          ),
        ),
      );
      Widget host(bool selected) => ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(main),
          appSettingsDatabaseProvider.overrideWithValue(main),
        ],
        child: _wrap(board(selected)),
      );

      Future<void> dragText() async {
        final rect = tester.getRect(find.byType(RichText));
        final gesture = await tester.startGesture(
          rect.centerLeft + const Offset(8, 0),
          kind: PointerDeviceKind.mouse,
        );
        await gesture.moveTo(rect.centerLeft + const Offset(140, 0));
        await tester.pump();
        await gesture.up();
        await tester.pump();
      }

      try {
        await tester.pumpWidget(host(true));
        await tester.pumpAndSettle();

        final rich = tester.widget<RichText>(find.byType(RichText));
        expect(rich.selectionRegistrar, isNotNull);
        await dragText();
        expect(pans, 0);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(clipboardText, isNotNull);
        expect(source.contains(clipboardText!), isTrue);
        expect(clipboardText!.trim().length, greaterThan(4));

        pans = 0;
        await tester.pumpWidget(host(false));
        await tester.pumpAndSettle();
        expect(
          tester.widget<RichText>(find.byType(RichText)).selectionRegistrar,
          isNull,
        );
        await dragText();
        expect(pans, 1);

        await tester.pumpWidget(host(true));
        await tester.pumpAndSettle();
        final point = tester.getCenter(find.byType(RichText));
        await tester.tapAt(point, kind: PointerDeviceKind.mouse);
        await tester.pump(kDoubleTapMinTime);
        await tester.tapAt(point, kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();
        expect(find.byType(RevericMarkdownEditor), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await db.close();
        await main.close();
      }
    },
  );
}
