// 职责: 验证剧本字体设置实时生效并保留编辑状态，以及跨场编辑、撤销和输入法行为。
// 关联文件:
//   lib/desktop/features/screenplay/script.dart
//   lib/desktop/features/screenplay/script_elements.dart
//   lib/shared/providers/screenplay_providers.dart
// 遵循的 Rules:
//   .agents/rules/testing.md
//   .agents/rules/i18n.md

import 'package:reveric/shared/widgets/screenplay/loading.dart';
import 'package:reveric/shared/widgets/screenplay/document_toolbar.dart';
import 'dart:io';
import 'dart:ui' show ImageByteFormat;
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reveric/desktop/features/screenplay/script.dart';
import 'package:reveric/shared/widgets/screenplay/editing_scope.dart';
import 'package:reveric/shared/widgets/screenplay/document_heading.dart';
import 'package:reveric/shared/widgets/screenplay/time_field.dart';
import 'package:reveric/shared/database/app_database.dart';
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/shared/models/content_status.dart';
import 'package:reveric/shared/models/novel_type.dart';
import 'package:reveric/shared/models/screenplay_element.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/shared/services/working_overlay.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    if (Platform.environment.containsKey('SCREENPLAY_CAPTURE_DIR')) {
      for (final family in ['Georgia', 'Roboto', 'Ahem']) {
        final path = family == 'Georgia'
            ? '/System/Library/Fonts/Supplemental/Georgia.ttf'
            : '/System/Library/Fonts/Supplemental/Arial.ttf';
        final loader = FontLoader(family)
          ..addFont(
            Future.value(ByteData.sublistView(await File(path).readAsBytes())),
          );
        await loader.load();
      }
    }
  });

  setUp(() => rootBundle.clear());

  testWidgets(
    'shared episode editor applies font settings and preserves cross-scene editing',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final appDb = AppDatabase.forTest(NativeDatabase.memory());
      final contentDb = NovelContentDatabase.forTest(NativeDatabase.memory());
      final service = ScreenplayService(contentDb, novelId: 'screenplay_1');
      final initial = await service.createInitialStructure();
      final root = (await contentDb.screenplayDao.getRoot())!;
      final a = await service.createScene(
        screenplayId: root.id,
        episodeId: initial.episodeId,
        timeLabel: 'Night',
      );
      final b = await service.createScene(
        screenplayId: root.id,
        episodeId: initial.episodeId,
        timeLabel: 'Day',
      );
      for (final (id, text) in [
        (a, 'The lamp goes out.'),
        (b, 'The door opens.'),
      ]) {
        await service.writeElements(
          sceneId: id,
          elements: [
            ScreenplayElement(type: ScreenplayElementType.action, text: text),
          ],
        );
      }
      const path = 'memory:desktop_screenplay_script';
      var font = const TextStyle(
        fontFamily: 'Georgia',
        fontSize: 16,
        height: 1.8,
        letterSpacing: 0,
      );
      Future<void> Function()? flush;
      await tester.pumpWidget(
        _wrap(
          ProviderScope(
            overrides: [
              appDatabaseProvider.overrideWithValue(appDb),
              editorFontFamilyProvider.overrideWith((ref) => font.fontFamily!),
              editorFontSizeProvider.overrideWith(
                (ref) => font.fontSize!.toInt(),
              ),
              editorLineHeightProvider.overrideWith((ref) => font.height!),
              editorLetterSpacingProvider.overrideWith(
                (ref) => font.letterSpacing!,
              ),
              editorFontColorProvider.overrideWith((ref) => font.color),
              novelContentDatabaseProvider(path).overrideWithValue(contentDb),
            ],
            child: Scaffold(
              body: ScreenplayScriptRegion(
                novel: _screenplay(path),
                registerFlush: (callback) => flush = callback,
              ),
            ),
          ),
        ),
      );
      // 工作区先异步恢复当前集，再进入正文加载帧。
      for (
        var frame = 0;
        frame < 30 && find.byType(ScreenplayLoading).evaluate().isEmpty;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(find.byType(ScreenplayLoading), findsOneWidget);
      expect(find.byType(ScreenplayEditingScope), findsNothing);
      final toolbar = find.byType(ScreenplayDocumentToolbar);
      final toolbarRect = tester.getRect(toolbar);
      expect(tester.widget<ScreenplayDocumentToolbar>(toolbar).actions, isNull);
      await tester.pumpAndSettle();
      expect(find.byType(ScreenplayLoading), findsNothing);
      expect(tester.getRect(toolbar), toolbarRect);

      expect(find.byType(ScreenplayEditingScope), findsOneWidget);
      final scope = tester.state<ScreenplayEditingScopeState>(
        find.byType(ScreenplayEditingScope),
      );
      final editor = scope.controller;
      final selectionBeforeRefresh = editor.selection;
      await service.updateScene(sceneId: a, synopsis: 'Updated in background');
      await tester.pumpAndSettle();
      expect(find.byType(ScreenplayLoading), findsNothing);
      expect(
        tester.state<ScreenplayEditingScopeState>(
          find.byType(ScreenplayEditingScope),
        ),
        same(scope),
      );
      expect(editor.selection, selectionBeforeRefresh);
      expect(tester.getRect(toolbar), toolbarRect);
      expect(editor.value.where((e) => e.isHeading), hasLength(2));
      expect(find.text('The lamp goes out.'), findsOneWidget);
      expect(find.text('The door opens.'), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ScreenplayEditingScope)),
      );
      TextStyle actionStyle() => tester
          .widget<EditableText>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is EditableText &&
                  widget.controller.text == 'The lamp goes out.',
            ),
          )
          .style;
      expect(actionStyle().fontFamily, 'Georgia');
      expect(actionStyle().fontSize, 16);
      final sourceBeforeFontChange = editor.source;
      final selectionBeforeFontChange = editor.selection;
      final initialFont = font;
      void refreshFont() {
        container.invalidate(editorFontFamilyProvider);
        container.invalidate(editorFontSizeProvider);
        container.invalidate(editorLineHeightProvider);
        container.invalidate(editorLetterSpacingProvider);
        container.invalidate(editorFontColorProvider);
      }

      font = const TextStyle(
        fontFamily: 'Roboto',
        fontSize: 20,
        height: 2,
        letterSpacing: 1,
        color: Color(0xFF754321),
      );
      refreshFont();
      await tester.pumpAndSettle();
      expect(actionStyle().fontFamily, font.fontFamily);
      expect(actionStyle().fontSize, font.fontSize);
      expect(actionStyle().height, font.height);
      expect(actionStyle().letterSpacing, font.letterSpacing);
      expect(actionStyle().color, font.color);
      final headingText = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byType(ScreenplayDocumentHeading).first,
              matching: find.byType(Text),
            ),
          )
          .firstWhere((text) => text.textSpan != null);
      expect(headingText.style!.fontFamily, font.fontFamily);
      expect(headingText.style!.fontSize, greaterThan(font.fontSize!));
      expect(editor.source, sourceBeforeFontChange);
      expect(editor.selection, selectionBeforeFontChange);
      expect(
        tester.state<ScreenplayEditingScopeState>(
          find.byType(ScreenplayEditingScope),
        ),
        same(scope),
      );
      expect(tester.getRect(toolbar), toolbarRect);
      if (Platform.environment['SCREENPLAY_CAPTURE_DIR']
          case final directory?) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byType(RepaintBoundary).first,
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ImageByteFormat.png);
          await File(
            '$directory/desktop.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }

      font = initialFont;
      refreshFont();
      await tester.pumpAndSettle();
      expect(actionStyle().fontFamily, 'Georgia');
      expect(actionStyle().fontSize, 16);
      final overlay = container.read(workingOverlayServiceProvider(path));
      final proposals = <String>[];
      for (final id in [a, b]) {
        proposals.add(
          (await overlay.stageCreateChange(
            resourcePath: '/scenes/$id',
            resourceType: 'screenplay_scenes',
            resourceId: id,
            previewText: 'AI',
            source: workingChangeSourceAi,
          )).id,
        );
      }
      editor.select(
        TextSelection(baseOffset: 0, extentOffset: editor.source.length),
      );
      expect(editor.selectedText(), contains('Day'));
      expect(
        (await contentDb.workingChangeDao.getById(proposals.first))!.status,
        workingChangeStatusActive,
      );
      await tester.tap(find.text('The lamp goes out.'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Transition'));
      await tester.pumpAndSettle();
      await flush!();
      expect(
        (await contentDb.screenplayDao.getElementRows(a)).single.type,
        'transition',
      );
      expect(
        (await contentDb.workingChangeDao.getById(proposals.first))!.status,
        workingChangeStatusCommitted,
      );
      expect(
        (await contentDb.workingChangeDao.getById(proposals.last))!.status,
        workingChangeStatusActive,
      );
      await tester.tap(find.text('Action'));
      await tester.pumpAndSettle();
      await flush!();

      // One selection passes through the actual heading row, in both directions.
      Offset point(int index, int offset) {
        final render = scope.rowAt(index)!.editable!.renderEditable;
        return render.localToGlobal(
          render.getLocalRectForCaret(TextPosition(offset: offset)).centerLeft,
        );
      }

      final mouse = await tester.startGesture(
        point(1, 4),
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveTo(point(3, 8));
      await tester.pump();
      await mouse.up();
      expect(editor.selectedText(), contains('Day'));
      expect(editor.selectedText(), isNot(contains('\uFFFC')));
      expect(editor.crossesElements, isTrue);
      final reverse = await tester.startGesture(
        point(3, 8),
        kind: PointerDeviceKind.mouse,
      );
      await reverse.moveTo(point(1, 4));
      await tester.pump();
      await reverse.up();
      expect(
        editor.selection.baseOffset,
        greaterThan(editor.selection.extentOffset),
      );

      final before = await service.readDocument(initial.episodeId);
      final replace = editor.replaceSelection('new ');
      await tester.pumpAndSettle();
      expect(find.text('Change scene structure'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await replace;
      expect((await service.readDocument(initial.episodeId)).sceneOrder, [
        a,
        b,
      ]);
      expect(editor.selectedText(), contains('Day'));
      final confirm = editor.replaceSelection('new ');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      await confirm;
      await flush!();
      await tester.pumpAndSettle();
      expect((await service.readDocument(initial.episodeId)).sceneOrder, [a]);
      editor.undo();
      await flush!();
      await tester.pumpAndSettle();
      expect((await service.readDocument(initial.episodeId)).sceneOrder, [
        a,
        b,
      ]);
      expect(
        (await service.readDocument(
          initial.episodeId,
        )).elements.map((e) => e.id),
        before.elements.map((e) => e.id),
      );

      editor.select(
        TextSelection(
          baseOffset: editor.startOf(1) + 4,
          extentOffset: editor.startOf(3) + 8,
        ),
      );
      final invalidated = editor.replaceSelection('outdated ');
      await tester.pumpAndSettle();
      await service.updateScene(
        sceneId: b,
        synopsis: 'Externally updated while confirming',
      );
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      await invalidated;
      expect((await service.readDocument(initial.episodeId)).sceneOrder, [
        a,
        b,
      ]);
      expect(
        (await contentDb.screenplayDao.getElementRows(a)).single.textContent,
        'The lamp goes out.',
      );

      // IME draft stays local until the composition is committed.
      await tester.tap(find.text('The lamp goes out.'));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byType(TextField).first);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '中文',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange(start: 0, end: 2),
        ),
      );
      await tester.pump(const Duration(milliseconds: 700));
      expect(field.focusNode!.hasFocus, isTrue);
      expect(
        (await contentDb.screenplayDao.getElementRows(a)).single.textContent,
        'The lamp goes out.',
      );
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '中文',
          selection: TextSelection.collapsed(offset: 2),
        ),
      );
      await tester.pumpAndSettle();
      await flush!();
      expect(
        (await contentDb.screenplayDao.getElementRows(a)).single.textContent,
        '中文',
      );

      // Scene command splits at the body caret and keeps both blocks editable.
      await tester.tap(find.text('Scene'));
      await tester.pumpAndSettle();
      await flush!();
      expect(
        (await service.readDocument(initial.episodeId)).sceneOrder,
        hasLength(3),
      );
      expect(find.byType(ScreenplayEditingScope), findsOneWidget);
      // Heading fields share the document save path; cancelled new locations stay local.
      final heading = find.byType(ScreenplayDocumentHeading).first;
      await tester.ensureVisible(heading);
      await tester.tap(
        find
            .descendant(of: heading, matching: find.byType(GestureDetector))
            .first,
      );
      await tester.pumpAndSettle();
      expect(find.byType(ScreenplayTimeField), findsOneWidget);
      // 新建地点的输入框按 fieldKey 定位：它已经从 TextFormField 换成
      // HookedTextFormField（内部是 RevericTextField 的 TextField）。
      final newLocationInput = find.byKey(
        const ValueKey('scene_new_location_field'),
      );
      expect(newLocationInput, findsNothing);
      await tester.tap(find.text('Create location'));
      await tester.pumpAndSettle();
      await tester.enterText(newLocationInput, 'Cancelled location');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel').first);
      await tester.pumpAndSettle();
      expect(newLocationInput, findsNothing);
      await tester.tap(find.text('Create location'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(newLocationInput).controller!.text, '');
      await tester.enterText(newLocationInput, 'Library');
      final timeInput = find.descendant(
        of: find.byType(ScreenplayTimeField),
        matching: find.byType(TextField),
      );
      await tester.enterText(timeInput, 'La');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      await tester.tap(find.widgetWithText(ListTile, 'Later'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      await flush!();
      final savedHeading = (await service.readDocument(
        initial.episodeId,
      )).elements.first;
      expect(savedHeading.timeLabel, 'Later');
      final places = await contentDb.select(contentDb.locations).get();
      expect(places.map((p) => p.name), ['Library']);
      expect(savedHeading.locationId, places.single.id);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      // 数据库关闭含异步流清理，让其在真实事件循环中完成。
      await tester.runAsync(() async {
        await contentDb.close();
        await appDb.close();
      });
    },
  );
}

Novel _screenplay(String databasePath) {
  final now = DateTime(2026);
  return Novel(
    id: 'screenplay_1',
    title: 'Screenplay Test',
    authorName: '',
    description: '',
    status: contentStatusInProgress,
    type: novelTypeOriginal,
    contentKind: contentKindScreenplay,
    contentDatabasePath: databasePath,
    wordCount: 0,
    draft: false,
    category: '',
    tags: const [],
    createdAt: now,
    updatedAt: now,
    deletedAt: notDeletedSentinel,
  );
}

Widget _wrap(Widget child) {
  if (child is ProviderScope) {
    return ProviderScope(overrides: child.overrides, child: _wrap(child.child));
  }
  return EasyLocalization(
    supportedLocales: const [Locale('en'), Locale('zh', 'CN')],
    path: 'assets/translations',
    assetLoader: const MergingAssetLoader(),
    fallbackLocale: const Locale('en'),
    startLocale: const Locale('en'),
    child: Builder(
      builder: (context) => RevericTheme(
        data: RevericThemeData.reveric,
        child: MaterialApp(
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          locale: context.locale,
          theme: RevericThemeData.reveric.toThemeData(),
          home: child,
        ),
      ),
    ),
  );
}
