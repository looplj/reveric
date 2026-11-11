// 职责: 验证制作节点卡片、参考素材缩略图、主体选择与资料弹窗的展示和交互。
// 关联文件:
//   lib/desktop/features/production/node_card.dart
//   lib/desktop/features/production/input_preview.dart
//   lib/desktop/features/production/image_node.dart
//   lib/shared/services/production/canvas_service.dart
import 'dart:io';
import 'package:reveric/desktop/features/production/voices.dart';
import 'dart:convert';
import 'package:drift/drift.dart' show Value;
import 'package:reveric/shared/models/production/asset_content.dart';

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:reveric/desktop/features/production/node_card.dart';
import 'package:reveric/desktop/features/production/history_region.dart';
import 'package:reveric/desktop/features/production/edit_session.dart';
import 'package:reveric/desktop/features/editing/canvas_shell.dart';
import 'package:reveric/desktop/features/production/editing_node.dart';
import 'package:reveric/shared/models/content_kind.dart';
import 'package:reveric/desktop/features/production/input_preview.dart';
import 'package:reveric/desktop/features/production/subject_picker.dart';
import 'package:reveric/shared/database/app_database.dart' as app;
import 'package:reveric/shared/database/novel_content_database.dart';
import 'package:reveric/shared/localization/merging_asset_loader.dart';
import 'package:reveric/shared/models/video/request.dart';
import 'package:reveric/shared/providers/novel_providers.dart';
import 'package:reveric/shared/providers/settings_providers.dart';
import 'package:reveric/desktop/features/production/node_title.dart';
import 'package:reveric/shared/widgets/md/reveric_markdown_editor.dart';
import 'package:reveric/shared/services/production/canvas_service.dart';
import 'package:reveric/shared/services/production/ffmpeg_runner.dart';
import 'package:reveric/shared/services/production/library_service.dart';
import 'package:reveric/shared/services/production/media_service.dart';
import 'package:reveric/shared/services/screenplay_service.dart';
import 'package:reveric/shared/services/storyboard/service.dart';
import 'package:reveric/shared/theme/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _wrap(Widget child, {TargetPlatform? platform}) => EasyLocalization(
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
      theme: RevericThemeData.reveric.toThemeData().copyWith(
        platform: platform,
      ),
      home: RevericTheme(
        data: RevericThemeData.reveric,
        child: Scaffold(body: child),
      ),
    ),
  ),
);

final _portHint = find.byWidgetPredicate(
  (widget) => widget.runtimeType.toString() == '_PortHint',
);

void main() {
  setUp(() => rootBundle.clear());
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  testWidgets(
    'editing node opens its project and remains removable when the project disappears',
    (tester) async {
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      final main = app.AppDatabase.forTest(NativeDatabase.memory());
      await ScreenplayService(db).createCanvasStructure();
      final service = ProductionCanvasService(
        StoryboardService(db, contentKind: contentKindCanvas),
        MediaLibraryService(
          main,
          MediaService(FfmpegRunner()),
          Directory.systemTemp,
        ),
        'work',
      );
      final canvas = await service.ensureCanvas('');
      final node = await service.addEditing(canvas.id, title: 'Cut A');
      String? opened;
      try {
        await tester.pumpWidget(
          ProviderScope(
            child: _wrap(
              Center(
                child: SizedBox(
                  width: 260,
                  height: 180,
                  child: CanvasEditingScope(
                    open: (id) async => opened = id,
                    child: ProductionNodeCard(
                      service: service,
                      node: node,
                      selected: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Cut A'), findsOneWidget);
        expect(productionNodePorts(node, derived: false), (
          input: false,
          output: false,
        ));
        await tester.tap(find.byType(ProductionEditingNode));
        await tester.pump(const Duration(milliseconds: 60));
        await tester.tap(find.byType(ProductionEditingNode));
        await tester.pumpAndSettle();
        expect(opened, node.id);
        opened = null;
        await db.editingDao.softDelete(node.editingId!);
        await tester.pumpAndSettle();
        expect(find.text('Editing project is unavailable'), findsOneWidget);
        await tester.tap(find.byType(ProductionEditingNode));
        await tester.pump(const Duration(milliseconds: 60));
        await tester.tap(find.byType(ProductionEditingNode));
        await tester.pumpAndSettle();
        expect(opened, isNull);
        await service.removeNode(node.id);
        expect(await db.canvasDao.getNodeById(node.id), isNull);
        expect(await db.editingDao.get(node.editingId!), isNull);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await db.close();
        await main.close();
      }
    },
  );

  testWidgets(
    'text node edits preserve drafts, save once and show text-only input actions',
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
      final text = await service.addText(
        canvas.id,
        title: 'Note',
        content: 'Original text',
      );
      final history = CanvasHistory(service.shots, canvas.id);
      final session = ProductionEditSession();
      // 画布把标题输入放在节点之外的浮层里；这里直接摆在卡片上方。
      final title = ProductionNodeTitle();
      addTearDown(title.dispose);
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
                session: session,
                child: Center(
                  child: SizedBox(
                    width: 260,
                    height: 300,
                    child: Column(
                      children: [
                        SizedBox(
                          height: 40,
                          child: ProductionNodeTitleField(
                            title: title,
                            nodeId: text.id,
                          ),
                        ),
                        Expanded(
                          child: StreamBuilder<CanvasNode?>(
                            stream: db.canvasDao.watchNodeById(text.id),
                            initialData: text,
                            builder: (context, snapshot) => ProductionNodeCard(
                              service: service,
                              node: snapshot.data!,
                              selected: true,
                              textTitle: title,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(productionNodePorts(text, derived: false), (
          input: false,
          output: true,
        ));
        // 没有编辑按钮：双击正文进入编辑。
        await tester.tap(find.byType(RevericMarkdownPreview));
        await tester.pump(kDoubleTapMinTime);
        await tester.tap(find.byType(RevericMarkdownPreview));
        await tester.pumpAndSettle();
        final fields = find.byType(EditableText);
        await tester.enterText(fields.at(0), 'Shared direction');
        // 正文是 Markdown 编辑器，没有 EditableText；通过它的外部 controller 写入。
        TextEditingController body() => tester
            .widget<RevericMarkdownEditor>(find.byType(RevericMarkdownEditor))
            .controller;
        body().text = 'Edited description';
        await service.updateText(
          text.id,
          title: 'AI update',
          content: 'Background change',
        );
        await tester.pumpAndSettle();
        expect(body().text, 'Edited description');
        expect(history.undoCount, 0);
        // 没有保存按钮：焦点同时离开标题和正文即保存并退出编辑。
        FocusManager.instance.primaryFocus!.unfocus();
        await tester.pumpAndSettle();
        expect(find.byType(RevericMarkdownEditor), findsNothing);
        expect(history.undoCount, 1);
        final saved = await service.requireNode(text.id);
        expect(saved.title, 'Shared direction');
        expect(saved.content, 'Edited description');
        await history.undo();
        await tester.pumpAndSettle();
        expect(
          (await service.requireNode(text.id)).content,
          'Background change',
        );
        // 没有编辑按钮：双击正文进入编辑。
        await tester.tap(find.byType(RevericMarkdownPreview));
        await tester.pump(kDoubleTapMinTime);
        await tester.tap(find.byType(RevericMarkdownPreview));
        await tester.pumpAndSettle();
        body().text = 'Saved on leaving';
        expect(await session.close(), isTrue);
        await tester.pumpAndSettle();
        expect(
          (await service.requireNode(text.id)).content,
          'Saved on leaving',
        );

        var moved = 0;
        var removed = false;
        await tester.pumpWidget(
          _wrap(
            Center(
              child: ProductionInputTile(
                service: service,
                input: ProductionInput.text(text.id),
                valid: true,
                onRole: (_) => fail('Text has no media role menu'),
                onMove: (delta) => moved = delta,
                onRemove: () => removed = true,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Text'), findsOneWidget);
        expect(find.text('Saved on leaving'), findsOneWidget);
        await tester.tap(find.byType(ProductionInputTile));
        await tester.pumpAndSettle();
        expect(find.text('Reference image'), findsNothing);
        expect(find.text('Preview adopted result'), findsNothing);
        await tester.tap(find.text('Move up'));
        await tester.pumpAndSettle();
        expect(moved, -1);
        await tester.tap(find.byType(ProductionInputTile));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Disconnect'));
        await tester.pumpAndSettle();
        expect(removed, isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        history.dispose();
        await db.close();
        await main.close();
      }
    },
  );

  testWidgets(
    'middle frame menus follow model support and show sequence labels',
    (tester) async {
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      final main = app.AppDatabase.forTest(NativeDatabase.memory());
      final service = ProductionCanvasService(
        StoryboardService(db),
        MediaLibraryService(
          main,
          MediaService(FfmpegRunner()),
          Directory.systemTemp,
        ),
        'work',
      );
      final input = ProductionInput.asset(
        'missing',
        VideoInputRole.middle_frame,
      );
      VideoInputRole? selected;
      try {
        for (final (supported, mode, label, roleLabel) in [
          (false, VideoMode.first_last_frame, 'Middle 2', 'Middle frame'),
          (true, VideoMode.first_last_frame, 'Middle 2', 'Middle frame'),
          (
            true,
            VideoMode.reference,
            'Middle ref. 2',
            'Middle-frame reference',
          ),
        ]) {
          await tester.pumpWidget(
            _wrap(
              Center(
                child: ProductionInputTile(
                  service: service,
                  input: input,
                  mode: mode,
                  supportsMiddleFrames: supported,
                  middleFrameIndex: 2,
                  valid: supported,
                  onRole: (role) => selected = role,
                  onMove: null,
                  onRemove: () {},
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text(label), findsOneWidget);
          await tester.tap(find.byType(ProductionInputTile));
          await tester.pumpAndSettle();
          expect(
            find.text(roleLabel),
            supported ? findsOneWidget : findsNothing,
          );
          if (supported) {
            await tester.tap(find.text(roleLabel));
            expect(selected, VideoInputRole.middle_frame);
          } else {
            await tester.tap(find.text('First frame'));
            expect(selected, VideoInputRole.first_frame);
          }
          await tester.pumpAndSettle();
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await db.close();
        await main.close();
      }
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.macOS,
    }),
  );

  testWidgets(
    'shared voices can be renamed and unlinked',
    (tester) async {
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      final main = app.AppDatabase.forTest(NativeDatabase.memory());
      final service = ProductionCanvasService(
        StoryboardService(db),
        MediaLibraryService(
          main,
          MediaService(FfmpegRunner()),
          Directory.systemTemp,
        ),
        'work',
      );
      try {
        await db
            .into(db.characterProfiles)
            .insert(
              CharacterProfilesCompanion.insert(
                id: 'hero',
                name: 'Hero',
                voices: const Value([
                  CharacterVoice(assetId: 'one', name: 'Normal'),
                  CharacterVoice(assetId: 'two', name: 'Young'),
                ]),
              ),
            );
        await tester.pumpWidget(
          _wrap(
            Builder(
              builder: (context) => TextButton(
                onPressed: () => showProductionVoices(context, service, 'hero'),
                child: const Text('Open'),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open'));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();
        expect(find.text('Normal'), findsOneWidget);
        expect(find.text('Young'), findsOneWidget);
        await tester.tap(find.byTooltip('Rename').first);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Calm');
        await tester.tap(find.text('Save'));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();
        expect(find.text('Calm'), findsOneWidget);
        expect(
          (await db.characterProfileDao.getById('hero'))!.voices!.first.name,
          'Calm',
        );
        final second = find.byKey(const ValueKey('voice-two'));
        await tester.tap(
          find.descendant(of: second, matching: find.byTooltip('Remove')),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();
        expect(find.text('Young'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await db.close();
        await main.close();
      }
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.macOS,
    }),
  );

  testWidgets(
    'reference input renders the asset image when its id is not a file path',
    (tester) async {
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      final main = app.AppDatabase.forTest(NativeDatabase.memory());
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('production-input-'),
      ))!;
      final file = File(
        '${root.path}/file_workspaces/work/images/reference.png',
      );
      try {
        await tester.runAsync(() async {
          await file.parent.create(recursive: true);
          await file.writeAsBytes(
            base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
            ),
          );
        });
        await main.assetDao.insertAsset(
          app.AssetsCompanion.insert(
            id: 'image_asset_reference',
            type: 'image',
            purpose: 'upload',
            path: const Value('file_workspaces/work/images/reference.png'),
            content: const Value(ImageAssetContent(mimeType: 'image/png')),
          ),
        );
        final service = ProductionCanvasService(
          StoryboardService(db),
          MediaLibraryService(main, MediaService(FfmpegRunner()), root),
          'work',
        );
        await tester.pumpWidget(
          _wrap(
            Center(
              child: ProductionInputTile(
                service: service,
                input: ProductionInput.asset(
                  'image_asset_reference',
                  VideoInputRole.reference_image,
                ),
                valid: true,
                onRole: null,
                onMove: null,
                onRemove: () {},
              ),
            ),
          ),
        );
        final decodedImage = find.byWidgetPredicate(
          (widget) => widget is RawImage && widget.image != null,
        );
        // 文件读取和图片解码需要真实事件循环；只推进假时钟不会完成。
        for (var i = 0; i < 50 && decodedImage.evaluate().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
          expect(tester.takeException(), isNull);
        }
        expect(decodedImage, findsOneWidget);
        expect(find.byType(ErrorWidget), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await db.close();
        await main.close();
        await tester.runAsync(() => root.delete(recursive: true));
      }
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.macOS,
    }),
  );

  testWidgets(
    'image node shows name-only header, empty actions and hover ports',
    (tester) async {
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      final main = app.AppDatabase.forTest(NativeDatabase.memory());
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('node-card-'),
      ))!;
      final shots = StoryboardService(db);
      final episode = (await ScreenplayService(
        db,
      ).createInitialStructure()).episodeId;
      final untitled = await shots.ensureClipNode(
        (await shots.createImage(
          episode,
          values: {'prompt': 'A quiet harbor at dawn'},
        )).id,
      );
      final named = await shots.ensureClipNode(
        (await shots.createImage(episode, values: {'title': 'Harbor'})).id,
      );
      final service = ProductionCanvasService(
        shots,
        MediaLibraryService(main, MediaService(FfmpegRunner()), root),
        'work',
      );
      Widget card(
        CanvasNode node, {
        bool selected = false,
        bool Function()? compact,
      }) => SizedBox.fromSize(
        size: productionNodeSize(node, aspect: 1),
        child: ProductionNodeCard(
          service: service,
          node: node,
          selected: selected,
          compact: compact,
        ),
      );
      Future<void> show(Widget child) async {
        await tester.pumpWidget(
          _wrap(
            Padding(
              padding: const EdgeInsets.all(40),
              child: Align(alignment: Alignment.topLeft, child: child),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      try {
        await show(card(untitled));
        final cardFinder = find.byType(ProductionNodeCard);
        // 没有名字时标题退回类型，画在卡片上沿之外。
        final type = find.descendant(
          of: cardFinder,
          matching: find.text('Image'),
        );
        expect(type, findsOneWidget);
        expect(
          tester.getRect(type).bottom,
          lessThanOrEqualTo(tester.getRect(cardFinder).top),
        );
        expect(find.text('A quiet harbor at dawn'), findsNothing);
        expect(find.text('Upload'), findsOneWidget);
        expect(find.text('Asset library'), findsOneWidget);
        expect(_portHint, findsNothing);

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: tester.getCenter(cardFinder));
        addTearDown(mouse.removePointer);
        await tester.pumpAndSettle();
        expect(_portHint, findsNWidgets(2));
        await mouse.moveTo(Offset.zero);
        await tester.pumpAndSettle();
        expect(_portHint, findsNothing);

        await show(card(untitled, selected: true));
        expect(_portHint, findsNWidgets(2));

        // 有名字只写名字，不再重复类型。
        await show(card(named));
        expect(find.text('Harbor'), findsOneWidget);
        expect(find.text('Image'), findsNothing);

        await db
            .into(db.items)
            .insert(
              ItemsCompanion.insert(
                id: 'guild',
                type: 'faction',
                title: 'Guild',
              ),
            );
        final compendium = await service.addSubject(
          named.canvasId,
          itemId: 'guild',
        );
        final compendiumClip = (await shots.getShot(compendium.clipId!))!;
        await shots.apply(compendiumClip.id, {
          ...shots.snapshot(compendiumClip),
          'title': '',
        });
        await show(card(compendium));
        expect(find.text('Compendium'), findsOneWidget);
        expect(find.text('Image'), findsNothing);

        // 缩小到骨架：空画面只留图标，提示词和入口按钮不画，卡片外标题照旧。
        await show(card(untitled, compact: () => true));
        expect(find.text('Image'), findsOneWidget);
        expect(find.text('A quiet harbor at dawn'), findsNothing);
        expect(find.text('Upload'), findsNothing);
        expect(find.text('Asset library'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await db.close();
        await main.close();
        await tester.runAsync(() => root.delete(recursive: true));
      }
    },
  );
  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    testWidgets(
      '$platform compendium picker filters by type and searches all four types',
      (tester) async {
        final db = NovelContentDatabase.forTest(NativeDatabase.memory());
        final main = app.AppDatabase.forTest(NativeDatabase.memory());
        final service = ProductionCanvasService(
          StoryboardService(db),
          MediaLibraryService(
            main,
            MediaService(FfmpegRunner()),
            Directory.systemTemp,
          ),
          'work',
        );
        for (final type in compendiumEntityTypes) {
          await db
              .into(db.items)
              .insert(
                ItemsCompanion.insert(
                  id: type,
                  type: type,
                  title: '$type entry',
                ),
              );
        }
        await db
            .into(db.items)
            .insert(
              ItemsCompanion.insert(
                id: 'deleted',
                type: 'item',
                title: 'Deleted entry',
                deletedAt: Value(DateTime.now()),
              ),
            );
        String? picked;
        try {
          await tester.pumpWidget(
            _wrap(
              Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    picked = await pickProductionSubject(
                      context,
                      service,
                      kind: SubjectKind.compendium,
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
              platform: platform,
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();
          expect(find.text('Compendium'), findsOneWidget);
          for (final type in compendiumEntityTypes) {
            expect(find.text('$type entry'), findsOneWidget);
          }
          expect(find.text('Deleted entry'), findsNothing);
          await tester.tap(find.text('Factions 1'));
          await tester.pumpAndSettle();
          expect(find.text('faction entry'), findsOneWidget);
          expect(find.text('skill entry'), findsNothing);
          await tester.tap(find.text('All 4'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), 'skill');
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pumpAndSettle();
          expect(find.text('item entry'), findsNothing);
          expect(find.text('skill entry'), findsOneWidget);
          await tester.tap(find.text('skill entry'));
          await tester.pumpAndSettle();
          expect(picked, 'skill');
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await db.close();
          await main.close();
        }
      },
    );
  }
  for (final character in [true, false]) {
    testWidgets(
      '${character ? 'character' : 'location'} profile removes photos and still adopts',
      (tester) async {
        final db = NovelContentDatabase.forTest(NativeDatabase.memory());
        final main = app.AppDatabase.forTest(NativeDatabase.memory());
        final shots = StoryboardService(db);
        final service = ProductionCanvasService(
          shots,
          MediaLibraryService(
            main,
            MediaService(FfmpegRunner()),
            Directory.systemTemp,
          ),
          'work',
        );
        String? picked;
        try {
          final episode = (await ScreenplayService(
            db,
          ).createInitialStructure()).episodeId;
          final canvas = await shots.ensureCanvas(episode);
          if (character) {
            await db
                .into(db.characterProfiles)
                .insert(
                  CharacterProfilesCompanion.insert(
                    id: 'hero',
                    name: 'Clyde',
                    identity: const Value('Painter'),
                    appearance: const Value('Black hair, slim build'),
                    photos: const Value([
                      SubjectPhoto(assetId: 'front'),
                      SubjectPhoto(assetId: 'side'),
                    ]),
                  ),
                );
          } else {
            await db
                .into(db.locations)
                .insert(
                  LocationsCompanion.insert(
                    id: 'hero',
                    name: 'Studio',
                    description: const Value('Painter studio'),
                    photos: const Value([
                      SubjectPhoto(assetId: 'front'),
                      SubjectPhoto(assetId: 'side'),
                    ]),
                  ),
                );
          }
          final node = await service.addSubject(
            canvas.id,
            characterId: character ? 'hero' : null,
            locationId: character ? null : 'hero',
          );
          final clip = (await shots.getShot(node.clipId!))!;
          await tester.binding.setSurfaceSize(const Size(1200, 900));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(
            ProviderScope(
              overrides: [appDatabaseProvider.overrideWithValue(main)],
              child: _wrap(
                Builder(
                  builder: (context) => TextButton(
                    onPressed: () async {
                      picked = await showProductionSubjectProfile(
                        context,
                        service,
                        clip,
                      );
                    },
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Open'));
          // drift 的 watch 查询要真实事件循环推进，假时钟下不会出结果。
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pumpAndSettle();
          expect(find.text('Profile'), findsOneWidget);
          if (character) {
            expect(find.text('Identity'), findsOneWidget);
            expect(find.text('Painter'), findsOneWidget);
            expect(find.text('Character Appearance'), findsOneWidget);
            expect(find.text('Black hair, slim build'), findsOneWidget);
          } else {
            expect(find.text('Painter studio'), findsOneWidget);
          }
          expect(find.text('Photos'), findsOneWidget);
          expect(find.text('Close'), findsOneWidget);
          final remove = find.byKey(
            const ValueKey('remove-subject-photo-side'),
          );
          expect(remove, findsNothing);
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(
            location: tester.getCenter(
              find.byKey(const ValueKey('subject-photo-side')),
            ),
          );
          addTearDown(mouse.removePointer);
          await tester.pump();
          await tester.tap(remove);
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('subject-photo-side')),
            findsNothing,
          );
          expect(find.byType(ProductionSubjectProfileDialog), findsOneWidget);
          expect(picked, isNull);
          expect(
            await tester.runAsync(() => service.subjectPhotos(clip)),
            const [SubjectPhoto(assetId: 'front')],
          );
          await tester.tap(find.byKey(const ValueKey('subject-photo-front')));
          await tester.pumpAndSettle();
          expect(picked, 'front');
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await db.close();
          await main.close();
        }
      },
    );
  }
  testWidgets(
    'soft-deleting an asset invalidates its media card without deleting the file',
    (tester) async {
      final db = NovelContentDatabase.forTest(NativeDatabase.memory());
      final main = app.AppDatabase.forTest(NativeDatabase.memory());
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('deleted-media-card-'),
      ))!;
      final file = File('${root.path}/file_workspaces/work/images/asset.png');
      await tester.runAsync(() async {
        await file.parent.create(recursive: true);
        await file.writeAsBytes(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
          ),
        );
      });
      final shots = StoryboardService(db);
      final episode = (await ScreenplayService(
        db,
      ).createInitialStructure()).episodeId;
      final canvas = await shots.ensureCanvas(episode);
      await main.assetDao.insertAsset(
        app.AssetsCompanion.insert(
          id: 'asset',
          type: 'image',
          purpose: 'upload',
          path: const Value('file_workspaces/work/images/asset.png'),
          content: const Value(ImageAssetContent(mimeType: 'image/png')),
        ),
      );
      await db
          .into(db.canvasNodes)
          .insert(
            CanvasNodesCompanion.insert(
              id: 'node',
              canvasId: canvas.id,
              type: const Value(canvasNodeTypeMedia),
              refType: const Value(canvasNodeRefTypeAsset),
              refId: const Value('asset'),
            ),
          );
      final node = (await db.canvasDao.getNodeById('node'))!;
      final service = ProductionCanvasService(
        shots,
        MediaLibraryService(main, MediaService(FfmpegRunner()), root),
        'work',
      );
      try {
        await tester.pumpWidget(
          _wrap(
            Center(
              child: SizedBox(
                width: 220,
                height: 220,
                child: ProductionNodeCard(
                  service: service,
                  node: node,
                  selected: false,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await main.assetDao.softDeleteAsset('asset');
        await tester.pumpAndSettle();
        expect(
          find.text(
            'The selected file is missing. Choose another file or import it again.',
          ),
          findsOneWidget,
        );
        expect(await tester.runAsync(file.exists), isTrue);
        expect((await db.canvasDao.getNodeById('node'))!.refId, 'asset');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await db.close();
        await main.close();
        await tester.runAsync(() => root.delete(recursive: true));
      }
    },
  );
}
