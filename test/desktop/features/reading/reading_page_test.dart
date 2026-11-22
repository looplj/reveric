// 职责: 验证桌面端阅读页从章节详情流加载并格式化正文，且在主窗口与独立子窗口中正确避让标题栏与阅读工具栏。
// 关联文件:
//   lib/desktop/features/reading/reading_page.dart
//   lib/desktop/widgets/desktop_window_frame.dart
//   lib/shared/models/chapter.dart
//   lib/shared/providers/novel_providers.dart
//   lib/shared/localization/locale_keys.dart
//   assets/translations/en/reading.json
//   assets/translations/zh-CN/reading.json
// 遵循的 Rules:
//   .agents/rules/design-system.md
//   .agents/rules/desktop-window-frame.md
//   .agents/rules/i18n.md

import 'dart:async';

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/desktop/features/narration/dialog.dart';
import 'package:reveric/desktop/features/reading/reading_page.dart';
import 'package:reveric/desktop/widgets/desktop_window_frame.dart';
import 'package:reveric/shared/components/reveric_icon_button.dart';
import 'package:reveric/shared/database/app_database.dart' show AppDatabase;
import 'package:reveric/shared/localization/locale_keys.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/chapter.dart';
import 'package:reveric/shared/models/narration.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  setUp(rootBundle.clear);

  testWidgets(
    'read aloud waits for the selected chapter body after a chapter switch',
    (tester) async {
      final database = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(database.close);
      final secondChapter = StreamController<Chapter>();
      addTearDown(secondChapter.close);
      await _pumpReadingPage(
        tester,
        detachedWindow: true,
        database: database,
        secondChapter: secondChapter.stream,
      );

      final narrationButton = find.byWidgetPredicate(
        (widget) =>
            widget is RevericIconButton &&
            widget.tooltip == tr(LocaleKeys.narrationTitle),
      );
      expect(
        tester.widget<RevericIconButton>(narrationButton).onPressed,
        isNotNull,
      );
      await tester.tap(find.text(tr(LocaleKeys.readingNextChapter)));
      await tester.pump();
      expect(
        tester.widget<RevericIconButton>(narrationButton).onPressed,
        isNull,
      );

      secondChapter.add(_secondChapter(content: 'Current chapter body'));
      await tester.pumpAndSettle();
      await tester.tap(narrationButton);
      await tester.pumpAndSettle();
      final dialog = tester.widget<NarrationDialog>(
        find.byType(NarrationDialog),
      );
      expect(dialog.workId, 'reading_test_novel');
      expect(
        (dialog.source as NovelNarrationSource).text,
        'Current chapter body',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'continuous reading narrates the chapter visible after scrolling',
    (tester) async {
      final database = AppDatabase.forTest(NativeDatabase.memory());
      addTearDown(database.close);
      final body = List.filled(45, 'Current chapter body.').join('\n');
      await _pumpReadingPage(
        tester,
        database: database,
        readingMode: DesktopReadingMode.continuous_scroll,
        secondChapter: Stream.value(_secondChapter(content: body)),
      );
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -650));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip(tr(LocaleKeys.narrationTitle)));
      await tester.pumpAndSettle();
      final dialog = tester.widget<NarrationDialog>(
        find.byType(NarrationDialog),
      );
      expect((dialog.source as NovelNarrationSource).text, body);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'loads body from chapter detail below the desktop reading toolbar',
    (tester) async {
      await _pumpReadingPage(tester);

      final content = find.text('\u3000\u3000Reader content');
      expect(content, findsOneWidget);
      expect(tester.getTopLeft(content).dx, moreOrLessEquals(344, epsilon: 1));
      expect(tester.getTopLeft(content).dy, greaterThanOrEqualTo(104));
      expect(find.byType(Scrollbar), findsNothing);
      expect(find.byTooltip(tr(LocaleKeys.readingExit)), findsOneWidget);
      expect(find.byTooltip(tr(LocaleKeys.readingPinWindow)), findsNothing);
      // 自定义标题不能吞掉序号：正文标题与顶栏都显示「Chapter 7 Chapter one」。
      expect(find.text('Chapter 7 Chapter one'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'detached window places the toolbar at the top and hides the back button',
    (tester) async {
      final content = find.text('\u3000\u3000Reader content');
      final toc = find.byTooltip(tr(LocaleKeys.readingTableOfContents));
      await _pumpReadingPage(tester);
      final framedContentTop = tester.getTopLeft(content).dy;
      final framedTocTop = tester.getTopLeft(toc).dy;

      final pinChanges = <bool>[];
      await _pumpReadingPage(
        tester,
        detachedWindow: true,
        onPinnedChanged: pinChanges.add,
      );

      // 原生标题栏不占内容区：工具栏与正文整体上移一个自绘标题栏高度。
      expect(
        tester.getTopLeft(toc).dy,
        moreOrLessEquals(
          framedTocTop - DesktopWindowFrame.titleBarHeight,
          epsilon: 1,
        ),
      );
      expect(
        tester.getTopLeft(content).dy,
        moreOrLessEquals(
          framedContentTop - DesktopWindowFrame.titleBarHeight,
          epsilon: 1,
        ),
      );
      expect(find.byTooltip(tr(LocaleKeys.readingExit)), findsNothing);

      // 置顶按钮把下一状态交给窗口宿主，按当前状态切换提示。
      await tester.tap(find.byTooltip(tr(LocaleKeys.readingPinWindow)));
      expect(pinChanges, [true]);
      await _pumpReadingPage(
        tester,
        detachedWindow: true,
        pinned: true,
        onPinnedChanged: pinChanges.add,
      );
      await tester.tap(find.byTooltip(tr(LocaleKeys.readingUnpinWindow)));
      expect(pinChanges, [true, false]);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pumpReadingPage(
  WidgetTester tester, {
  bool detachedWindow = false,
  bool pinned = false,
  ValueChanged<bool>? onPinnedChanged,
  AppDatabase? database,
  Stream<Chapter>? secondChapter,
  DesktopReadingMode readingMode = DesktopReadingMode.chapter,
}) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    _wrap(
      ProviderScope(
        overrides: [
          if (database != null) appDatabaseProvider.overrideWithValue(database),
          if (database != null)
            appSettingsDatabaseProvider.overrideWithValue(database),
          desktopReadingModeProvider.overrideWithValue(readingMode),
          appBackgroundImagePathProvider.overrideWithValue(''),
          appBackgroundFitProvider.overrideWithValue(AppBackgroundFit.cover),
          appBackgroundThemeProvider.overrideWithValue(null),
          readingFontSizeProvider.overrideWithValue(30),
          readingMarginProvider.overrideWithValue(24),
          chapterTreeProvider('reading_test_db').overrideWith(
            // 章号只由章节树计算；正文详情直查原表，chapterNum 为空。
            (ref) => Stream.value([
              _chapter(content: '', chapterNum: 7),
              if (secondChapter != null) _secondChapter(),
            ]),
          ),
          chapterContentByIdProvider(
            path: 'reading_test_db',
            chapterId: 'chapter_test',
          ).overrideWith(
            (ref) => Stream.value(_chapter(content: 'Reader content')),
          ),
          if (secondChapter != null)
            chapterContentByIdProvider(
              path: 'reading_test_db',
              chapterId: 'chapter_two',
            ).overrideWith((ref) => secondChapter),
        ],
        child: DesktopReadingPage(
          novelId: 'reading_test_novel',
          novelTitle: 'A long work title',
          databasePath: 'reading_test_db',
          detachedWindow: detachedWindow,
          pinned: pinned,
          onPinnedChanged: onPinnedChanged,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Chapter _secondChapter({String content = ''}) => _chapter(
  content: content,
  id: 'chapter_two',
  title: 'Chapter two',
  siblingOrder: 1,
  chapterNum: 8,
);

Chapter _chapter({
  required String content,
  String id = 'chapter_test',
  String title = 'Chapter one',
  int siblingOrder = 0,
  int? chapterNum,
}) {
  final now = DateTime(2026);
  return Chapter(
    id: id,
    type: nodeTypeChapter,
    siblingOrder: siblingOrder,
    chapterNum: chapterNum,
    title: title,
    content: content,
    createdAt: now,
    updatedAt: now,
    deletedAt: notDeletedSentinel,
  );
}

Widget _wrap(Widget child) {
  return EasyLocalization(
    supportedLocales: const [Locale('en')],
    path: 'assets/translations',
    assetLoader: const MergingAssetLoader(),
    fallbackLocale: const Locale('en'),
    startLocale: const Locale('en'),
    child: Builder(
      builder: (context) {
        return RevericTheme(
          data: RevericThemeData.reveric,
          child: MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            theme: RevericThemeData.reveric.toThemeData(),
            home: Scaffold(body: child),
          ),
        );
      },
    ),
  );
}
